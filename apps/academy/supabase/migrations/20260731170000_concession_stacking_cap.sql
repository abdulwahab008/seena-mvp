-- FR-K08: concession stacking cap and expiry.
--
-- Accounting-specific care:
--   * The clamp lives in app.fn_plan_line_period_charges — the SQL
--     function challan generation (FR-K09) already calls — not in the
--     UI. The Notes are explicit about why: the cron path never touches
--     the UI, so a UI-level cap is no cap at all for the monthly batch
--     job. This migration widens that one function; every caller
--     (today, only generate_challans) gets the cap for free.
--   * Two clamps, not one, and they compose rather than replace each
--     other: the pre-existing per-line-gross clamp (a single line's
--     concession can never exceed that line's own amount — FR-K09's own
--     concern, unrelated to policy) and this FR's new tenant-wide
--     stacking clamp (combined awards on one line can never exceed
--     max_stacked_concession_pct of that line). Both apply; whichever is
--     tighter wins. A tenant with no fee_policy row behaves exactly as
--     before this migration — only the per-line-gross clamp applies.
--   * applied_award_ids on fee_challan_line is a plain array of every
--     award that contributed to that line's concession, capped or not —
--     the AC's "the challan shows the cap applied with both award ids
--     referenced" needs the ids visible on the challan itself, not just
--     derivable by re-querying concession_award after the fact.
--   * expire_due_concessions() only flips status; it does not touch
--     amount_paisa or delete anything, so an award's full history stays
--     intact. concession_award_audit (FR-K06's own AFTER UPDATE OR
--     DELETE trigger) already logs this transition to audit_log — that
--     "audit row per expired award" is the FR asks for, not a new table.
--
-- Scope cuts:
--   * No proportional-allocation rule is specified by the AC beyond "the
--     total is capped and both award ids are referenced" — this
--     migration does not attempt to decide how much of a capped total
--     "belongs to" which award (e.g. pro-rata by each award's own
--     percentage). applied_award_ids records participation, not a
--     per-award split of the clamped amount.
--   * allow_negative_net (in fee_policy's own object list) is stored but
--     not read anywhere yet — nothing in this schema currently produces
--     a negative net line to guard against; ck_challan_line_net_nonnegative
--     (FR-K09) already forbids it unconditionally. The column exists so
--     a future FR can opt a tenant out of that constraint without a
--     schema change; today every tenant is effectively "false".

create table public.fee_policy (
  tenant_id                  uuid primary key references public.tenant(id) on delete cascade,
  max_stacked_concession_pct numeric(5, 2) check (max_stacked_concession_pct is null or (max_stacked_concession_pct >= 0 and max_stacked_concession_pct <= 100)),
  allow_negative_net         boolean not null default false,
  updated_by                 uuid references public.app_user(user_id),
  updated_at                 timestamptz not null default clock_timestamp()
);

create or replace function public.set_fee_policy(p_max_stacked_concession_pct numeric default null, p_allow_negative_net boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.fee_policy (tenant_id, max_stacked_concession_pct, allow_negative_net, updated_by)
  values (app.auth_tenant_id(), p_max_stacked_concession_pct, p_allow_negative_net, auth.uid())
  on conflict (tenant_id) do update
    set max_stacked_concession_pct = excluded.max_stacked_concession_pct,
        allow_negative_net = excluded.allow_negative_net,
        updated_by = excluded.updated_by,
        updated_at = clock_timestamp();
end;
$$;

revoke execute on function public.set_fee_policy(numeric, boolean) from public, anon;
grant execute on function public.set_fee_policy(numeric, boolean) to authenticated;

alter table public.fee_policy enable row level security;

create policy fee_policy_tenant_read on public.fee_policy
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

alter table public.fee_challan_line add column applied_award_ids uuid[];

-- Widened: now tenant-scoped (for the stacking cap lookup) and returns
-- which awards contributed. Signature and return shape both change, so
-- CREATE OR REPLACE can't just widen it — drop first, same reasoning as
-- every other widened function in this module.
drop function if exists app.fn_plan_line_period_charges(uuid, uuid, date, date, int);

create or replace function app.fn_plan_line_period_charges(
  p_plan_id uuid, p_enrolment_id uuid, p_tenant_id uuid, p_period_start date, p_period_end date, p_month int
)
returns table (fee_head_id uuid, amount_paisa bigint, concession_paisa bigint, applied_award_ids uuid[])
language sql
stable
set search_path = ''
as $$
  select
    fpl.fee_head_id,
    fpl.amount_paisa,
    least(fpl.amount_paisa, coalesce(capped.total_concession, 0))::bigint as concession_paisa,
    capped.award_ids
  from public.fee_plan_line fpl
  left join lateral (
    select
      least(
        coalesce(sum(raw.amount), 0),
        -- max() here isn't really aggregating anything — the join is
        -- 1:1 per tenant — it's just the standard way to satisfy
        -- Postgres's "must appear in GROUP BY or be aggregated" rule
        -- for a column pulled in from outside the raw-awards subquery.
        case when max(policy.max_stacked_concession_pct) is not null
             then round(fpl.amount_paisa * max(policy.max_stacked_concession_pct) / 100.0)
             else fpl.amount_paisa
        end
      )::bigint as total_concession,
      array_agg(raw.award_id) as award_ids
    from (
      select ca.id as award_id,
             case ca.calc_type
               when 'percentage' then round(fpl.amount_paisa * ca.value / 100.0)
               else round(ca.value * 100)
             end as amount
        from public.concession_award ca
        join public.concession_scheme cs on cs.id = ca.scheme_id
       where ca.enrolment_id = p_enrolment_id
         and ca.status = 'approved'
         and ca.effective_from <= p_period_end
         and ca.effective_to >= p_period_start
         and cs.applicable_head_ids @> array[fpl.fee_head_id]
    ) raw
    left join public.fee_policy policy on policy.tenant_id = p_tenant_id
  ) capped on true
  where fpl.plan_id = p_plan_id
    and fpl.frequency <> 'one_time'
    and (fpl.billing_month_mask & (1 << (p_month - 1))) <> 0
    and fpl.effective_from <= p_period_end
    and (fpl.effective_to is null or fpl.effective_to >= p_period_start)
$$;

revoke execute on function app.fn_plan_line_period_charges(uuid, uuid, uuid, date, date, int) from public, anon, authenticated;

create or replace function public.generate_challans(
  p_campus_id uuid, p_session_id uuid, p_period date, p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_batch_id      uuid;
  v_month         int := extract(month from p_period)::int;
  v_period_start  date := date_trunc('month', p_period)::date;
  v_period_end    date := (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
  v_generated     int := 0;
  v_skipped       int := 0;
  v_failed        int := 0;
  v_enrol         record;
  v_gross         bigint;
  v_concession    bigint;
  v_gap_head      text;
  v_challan_id    uuid;
  v_challan_no    text;
  v_preview       jsonb := '{}'::jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not p_dry_run then
    insert into public.fee_challan_batch (tenant_id, campus_id, session_id, billing_period, requested_by)
    values (v_tenant_id, p_campus_id, p_session_id, v_period_start, auth.uid())
    returning id into v_batch_id;
  end if;

  for v_enrol in
    select e.id as enrolment_id, e.class_level_id, fp.id as plan_id, cl.name_en as class_name
      from public.enrolment e
      join public.student s on s.id = e.student_id
      join public.class_level cl on cl.id = e.class_level_id
      left join public.fee_plan fp on fp.enrolment_id = e.id
     where e.tenant_id = v_tenant_id and e.campus_id = p_campus_id and e.session_id = p_session_id
       and e.status = 'active' and s.status = 'active'
  loop
    if exists (
      select 1 from public.fee_challan
       where enrolment_id = v_enrol.enrolment_id and session_id = p_session_id
         and billing_period = v_period_start and status <> 'cancelled'
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if v_enrol.plan_id is null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'NO_FEE_PLAN');
      end if;
      continue;
    end if;

    select fh.code into v_gap_head
      from public.fee_head fh
     where fh.tenant_id = v_tenant_id and fh.is_mandatory
       and not exists (
         select 1 from public.fee_plan_line fpl where fpl.plan_id = v_enrol.plan_id and fpl.fee_head_id = fh.id
       )
     limit 1;
    if v_gap_head is not null then
      v_failed := v_failed + 1;
      if not p_dry_run then
        insert into public.fee_challan_batch_error (batch_id, enrolment_id, reason)
        values (v_batch_id, v_enrol.enrolment_id, 'MANDATORY_HEAD_COVERAGE_GAP: ' || v_gap_head);
      end if;
      continue;
    end if;

    select coalesce(sum(amount_paisa), 0), coalesce(sum(concession_paisa), 0)
      into v_gross, v_concession
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

    if v_gross = 0 then
      -- Nothing applicable this billing month (e.g. a quarterly-only plan
      -- between its billing months) — not a failure, just nothing to bill.
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if p_dry_run then
      v_preview := jsonb_set(
        v_preview, array[v_enrol.class_name],
        to_jsonb(coalesce((v_preview ->> v_enrol.class_name)::bigint, 0) + (v_gross - v_concession))
      );
      v_generated := v_generated + 1;
      continue;
    end if;

    v_challan_no := public.next_challan_no(v_tenant_id, p_campus_id, p_session_id);

    insert into public.fee_challan (
      tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no,
      due_date, gross_paisa, concession_paisa, net_paisa, batch_id
    ) values (
      v_tenant_id, p_campus_id, v_enrol.enrolment_id, p_session_id, v_period_start, v_challan_no,
      v_period_end + 10, v_gross, v_concession, v_gross - v_concession, v_batch_id
    ) returning id into v_challan_id;

    insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type, applied_award_ids)
    select v_challan_id, fee_head_id, amount_paisa, concession_paisa, amount_paisa - concession_paisa, 'charge', applied_award_ids
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_tenant_id, v_period_start, v_period_end, v_month);

    perform public.post_ledger_entry(
      v_enrol.enrolment_id, 'charge', v_gross, 'debit', null, v_period_start, 'fee_challan', v_challan_id
    );
    if v_concession > 0 then
      perform public.post_ledger_entry(
        v_enrol.enrolment_id, 'concession', v_concession, 'credit', null, v_period_start, 'fee_challan', v_challan_id
      );
    end if;

    v_generated := v_generated + 1;
  end loop;

  if not p_dry_run then
    update public.fee_challan_batch
       set generated_count = v_generated, skipped_count = v_skipped, failed_count = v_failed, completed_at = now()
     where id = v_batch_id;
  end if;

  return jsonb_build_object(
    'batch_id', v_batch_id, 'generated', v_generated, 'skipped', v_skipped, 'failed', v_failed,
    'dry_run', p_dry_run, 'preview_by_class', v_preview
  );
end;
$$;

-- generate_challans()'s own grants are unchanged by this migration but
-- CREATE OR REPLACE doesn't need them repeated — same signature as before.

-- Cross-tenant by construction, same posture as next_challan_no() and
-- apply_late_fees(): a cron job has no single tenant to scope to.
create or replace function public.expire_due_concessions(p_as_of date default current_date)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  update public.concession_award
     set status = 'expired'
   where status = 'approved' and effective_to < p_as_of;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.expire_due_concessions(date) from public, anon, authenticated;
grant execute on function public.expire_due_concessions(date) to service_role;
