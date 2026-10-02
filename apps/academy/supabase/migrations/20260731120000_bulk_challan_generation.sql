-- FR-K09: bulk monthly challan generation.
--
-- Consumes three things this module already shipped: FR-K04's fee_plan
-- snapshot (never the live fee_structure — a back-dated structure edit
-- must not rewrite an already-issued challan), FR-K06's approved
-- concession_award rows, and FR-K10's next_challan_no()/
-- challan_check_digit() for the number itself.
--
-- Accounting-specific care:
--   * Idempotency is a unique index (fee_challan_period_uq), not an
--     application-level "check first" — the AC's own framing ("a nervous
--     accountant re-runs it") is exactly the case a race between two
--     concurrent runs would otherwise double-bill. The generation loop
--     also does its own existence check up front so a re-run reports a
--     clean "skipped" count instead of hitting — and having to swallow —
--     a constraint violation per row.
--   * Money stays bigint paisa throughout; concession_scheme.value is
--     numeric rupees for a fixed_amount scheme (matches the UI's own
--     "Value (% or PKR)" label from FR-K05/K06), so it is *100'd at the
--     one point it enters a paisa column, exactly like every other
--     rupee-to-paisa boundary in this module.
--   * A partial failure (one enrolment's plan has a coverage gap) must
--     not abort the other 3,997 — each enrolment is its own iteration of
--     the loop with its own error captured to fee_challan_batch_error,
--     not one transaction-wide exception.
--   * The per-line concession clamp (never exceed that line's own gross)
--     is enforced twice on purpose: once in app.fn_plan_line_period_charges
--     via `least(...)`, and again as fee_challan_line's own
--     ck_challan_line_net_nonnegative CHECK — the constraint is the real
--     backstop, the LEAST() is just what keeps a dry-run preview honest
--     before any row exists to constrain.
--
-- Scope cuts (all real gaps, not swept under the rug):
--   * The tenant-wide *stacked* concession cap (e.g. "never more than 50%
--     combined") is FR-K08, not built — only a per-line, per-award clamp
--     exists here. Two 30%+40% awards on the same TUITION line today sum
--     to 70% off, not capped at a tenant policy; K08 is the FR that adds
--     that ceiling, in the SQL function, not the UI, per its own Notes.
--   * "Mandatory head coverage" is checked against the plan's full line
--     set (any period), not the requested billing month specifically —
--     good enough to route the AC's missing-TUITION-line case to
--     fee_challan_batch_error, but not group-aware the way K02's own
--     publish-time gate isn't either.
--   * arrears_paisa exists as a column (per the FR's own object list) but
--     nothing computes it yet — no FR in this module rolls forward an
--     unpaid balance into the next challan yet. Always 0 here.
--   * due_date is period-end + 10 days, a placeholder — FR-K12
--     (configurable late fee / due-date rules, holiday-shift aware) is
--     not built.
--   * The cron wiring (fees_generate_monthly_challans, day 25 at 01:00)
--     is not created — this environment has no pg_cron locally, same
--     limitation noted on every other cron-shaped FR in this catalogue.
--     generate_challans() is written to be called by that job once it
--     exists; today it's callable directly by an Accountant/Owner.
--   * Challan PDF rendering (FR-K11) is not built — fee_challan has no
--     associated document yet, just the row and its number.

create type public.fee_challan_status as enum ('unpaid', 'part_paid', 'paid', 'cancelled');
create type public.fee_challan_line_type as enum ('charge', 'concession', 'arrears', 'late_fee');

create table public.fee_challan_batch (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  billing_period  date not null,
  requested_by    uuid references public.app_user(user_id),
  generated_count int not null default 0,
  skipped_count   int not null default 0,
  failed_count    int not null default 0,
  started_at      timestamptz not null default now(),
  completed_at    timestamptz
);

create index idx_fee_challan_batch_campus_period on public.fee_challan_batch (campus_id, session_id, billing_period);

create table public.fee_challan_batch_error (
  id           uuid primary key default gen_random_uuid(),
  batch_id     uuid not null references public.fee_challan_batch(id) on delete cascade,
  enrolment_id uuid not null references public.enrolment(id),
  reason       text not null,
  created_at   timestamptz not null default now()
);

create index idx_fee_challan_batch_error_batch on public.fee_challan_batch_error (batch_id);

create table public.fee_challan (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  billing_period  date not null,
  challan_no      text not null,
  issue_date      date not null default current_date,
  due_date        date not null,
  gross_paisa     bigint not null check (gross_paisa >= 0),
  concession_paisa bigint not null default 0 check (concession_paisa >= 0),
  arrears_paisa   bigint not null default 0 check (arrears_paisa >= 0),
  net_paisa       bigint not null check (net_paisa >= 0),
  status          public.fee_challan_status not null default 'unpaid',
  batch_id        uuid references public.fee_challan_batch(id),
  created_at      timestamptz not null default now()
);

-- The idempotency control: a re-run for the same (enrolment, session,
-- period) finds its existing challan and skips, rather than relying on
-- application code to check first and racing a concurrent run.
create unique index fee_challan_period_uq on public.fee_challan (enrolment_id, session_id, billing_period)
  where status <> 'cancelled';
create index idx_fee_challan_batch on public.fee_challan (batch_id);

create trigger fee_challan_audit after insert or update or delete on public.fee_challan
  for each row execute function app.tg_audit_row();

create table public.fee_challan_line (
  id              uuid primary key default gen_random_uuid(),
  challan_id      uuid not null references public.fee_challan(id) on delete cascade,
  fee_head_id     uuid not null references public.fee_head(id),
  amount_paisa    bigint not null check (amount_paisa >= 0),
  concession_paisa bigint not null default 0 check (concession_paisa >= 0),
  net_paisa       bigint not null,
  line_type       public.fee_challan_line_type not null,
  constraint ck_challan_line_net_nonnegative check (net_paisa >= 0)
);

create index idx_fee_challan_line_challan on public.fee_challan_line (challan_id);

-- Now that fee_challan exists, bind FR-K14's ledger entries back to it —
-- the column has existed as a bare uuid since FR-K14 shipped, deferred
-- exactly for this migration.
alter table public.fee_ledger add constraint fee_ledger_challan_id_fkey
  foreign key (challan_id) references public.fee_challan(id);

-- Internal helper, not exposed as an RPC: the set of a plan's lines that
-- apply to one billing month, each with its own concession already
-- computed and clamped to its own gross (never negative net). Used twice
-- by generate_challans() below — once aggregated for the challan header,
-- once expanded for fee_challan_line — so the concession computation
-- lives in exactly one place.
create or replace function app.fn_plan_line_period_charges(
  p_plan_id uuid, p_enrolment_id uuid, p_period_start date, p_period_end date, p_month int
)
returns table (fee_head_id uuid, amount_paisa bigint, concession_paisa bigint)
language sql
stable
set search_path = ''
as $$
  select
    fpl.fee_head_id,
    fpl.amount_paisa,
    least(fpl.amount_paisa, coalesce((
      select sum(
        case ca.calc_type
          when 'percentage' then round(fpl.amount_paisa * ca.value / 100.0)
          else round(ca.value * 100)
        end
      )
      from public.concession_award ca
      join public.concession_scheme cs on cs.id = ca.scheme_id
      where ca.enrolment_id = p_enrolment_id
        and ca.status = 'approved'
        and ca.effective_from <= p_period_end
        and ca.effective_to >= p_period_start
        and cs.applicable_head_ids @> array[fpl.fee_head_id]
    ), 0))::bigint as concession_paisa
  from public.fee_plan_line fpl
  where fpl.plan_id = p_plan_id
    and fpl.frequency <> 'one_time'
    and (fpl.billing_month_mask & (1 << (p_month - 1))) <> 0
    and fpl.effective_from <= p_period_end
    and (fpl.effective_to is null or fpl.effective_to >= p_period_start)
$$;

revoke execute on function app.fn_plan_line_period_charges(uuid, uuid, date, date, int) from public, anon, authenticated;

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
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_period_start, v_period_end, v_month);

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

    insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type)
    select v_challan_id, fee_head_id, amount_paisa, concession_paisa, amount_paisa - concession_paisa, 'charge'
      from app.fn_plan_line_period_charges(v_enrol.plan_id, v_enrol.enrolment_id, v_period_start, v_period_end, v_month);

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

revoke execute on function public.generate_challans(uuid, uuid, date, boolean) from public, anon;
grant execute on function public.generate_challans(uuid, uuid, date, boolean) to authenticated;

alter table public.fee_challan_batch enable row level security;
alter table public.fee_challan_batch_error enable row level security;
alter table public.fee_challan enable row level security;
alter table public.fee_challan_line enable row level security;

create policy fee_challan_batch_campus_scope on public.fee_challan_batch
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_challan_batch_error_read on public.fee_challan_batch_error
  for select to authenticated
  using (
    batch_id in (
      select id from public.fee_challan_batch
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

create policy fee_challan_campus_scope on public.fee_challan
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_challan_line_read on public.fee_challan_line
  for select to authenticated
  using (
    challan_id in (
      select id from public.fee_challan
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
