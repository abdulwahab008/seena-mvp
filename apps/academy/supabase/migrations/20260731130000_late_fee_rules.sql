-- FR-K12: configurable late fee rules.
--
-- Accounting-specific care:
--   * compute_late_fee() is a pure, STABLE calculator with no side effect
--     — it answers "what would the late fee be as of this date", nothing
--     is posted or written. FR-K13 (nightly posting, not built here) is
--     the FR that actually turns this into a fee_ledger entry; this
--     migration's job is only to get the number right.
--   * Holiday/Sunday shifting moves a LOCAL copy of the due date used for
--     day-counting only — fee_challan.due_date itself, already computed
--     and stored by FR-K09 before this FR existed, is not rewritten here.
--     The AC's "the printed challan reflects the shifted date" is
--     therefore only half-satisfied: the shift is correctly computed and
--     used for every late-fee calculation, but retrofitting it into the
--     stored, already-issued due_date (and whatever already-printed PDF)
--     is out of scope for a rules migration — that belongs with FR-K09's
--     own due-date computation or FR-K11's PDF rendering, neither of
--     which exists yet in shift-aware form.
--   * "the exemption reason is recorded" (from the AC) is not implemented
--     here: compute_late_fee() has no side effect to record anything
--     into, and no daily job exists yet to own that audit row. It's
--     FR-K13's job once it posts something.
--   * Rule selection is "most recent rule whose effective_from has
--     arrived", per campus+session — there is no end-dating of a
--     superseded rule (no effective_to). A campus can only ever have one
--     rule take effect at a time going forward; this matches the AC's own
--     framing ("the rule cannot change retroactively for issued
--     challans") without needing a second column to express it, since
--     compute_late_fee() is always evaluated as-of a date, not cached.
--   * late_fee_rule_owner_write (named explicitly in the FR's own RLS
--     list) is enforced inside create_late_fee_rule()'s role check, not
--     as a separate RLS INSERT policy — consistent with every other
--     table in this module: the SECURITY DEFINER RPC is the only write
--     path, so there is no direct-insert client path that needs its own
--     policy to guard.
--   * holiday_calendar is NOT created here — FR-D11 (staff leave) already
--     shipped it (tenant_id, nullable campus_id meaning tenant-wide,
--     holiday_date, name), with its own add_holiday() RPC. Reusing it
--     rather than standing up a second, K12-flavoured calendar is the
--     obvious call: a gazetted public holiday is the same fact whether an
--     attendance job or a late-fee job is asking about it.

create type public.late_fee_basis as enum ('flat', 'per_day', 'percentage');

create table public.late_fee_rule (
  id                            uuid primary key default gen_random_uuid(),
  tenant_id                     uuid not null references public.tenant(id) on delete cascade,
  campus_id                     uuid not null references public.campus(id) on delete cascade,
  session_id                    uuid not null references public.academic_session(id) on delete cascade,
  grace_days                    int not null default 0 check (grace_days >= 0),
  basis                         public.late_fee_basis not null,
  amount_paisa                  bigint check (amount_paisa >= 0),
  percentage                    numeric(5, 2) check (percentage >= 0 and percentage <= 100),
  cap_paisa                     bigint check (cap_paisa >= 0),
  max_days                      int check (max_days >= 0),
  applicable_head_ids           uuid[],
  exempt_concession_categories  text[],
  effective_from                date not null default current_date,
  created_by                    uuid references public.app_user(user_id),
  -- clock_timestamp(), not now(): now() is frozen at transaction start, so
  -- two rules inserted in the same transaction would tie on created_at too
  -- — clock_timestamp() reads the actual wall clock at each row, which is
  -- what the effective_from tiebreak below actually needs to work.
  created_at                    timestamptz not null default clock_timestamp(),
  constraint ck_late_fee_rule_basis_fields check (
    (basis = 'percentage' and percentage is not null)
    or (basis in ('flat', 'per_day') and amount_paisa is not null)
  )
);

create index idx_late_fee_rule_campus_session on public.late_fee_rule (campus_id, session_id, effective_from desc);

create or replace function public.create_late_fee_rule(
  p_campus_id uuid, p_session_id uuid, p_basis public.late_fee_basis,
  p_grace_days int default 0, p_amount_paisa bigint default null, p_percentage numeric default null,
  p_cap_paisa bigint default null, p_max_days int default null,
  p_applicable_head_ids uuid[] default null, p_exempt_concession_categories text[] default null,
  p_effective_from date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_basis = 'percentage' and p_percentage is null then
    raise exception 'PERCENTAGE_REQUIRED' using errcode = '23514';
  end if;
  if p_basis in ('flat', 'per_day') and p_amount_paisa is null then
    raise exception 'AMOUNT_REQUIRED' using errcode = '23514';
  end if;

  insert into public.late_fee_rule (
    tenant_id, campus_id, session_id, grace_days, basis, amount_paisa, percentage, cap_paisa, max_days,
    applicable_head_ids, exempt_concession_categories, effective_from, created_by
  ) values (
    app.auth_tenant_id(), p_campus_id, p_session_id, p_grace_days, p_basis, p_amount_paisa, p_percentage, p_cap_paisa, p_max_days,
    p_applicable_head_ids, p_exempt_concession_categories, p_effective_from, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_late_fee_rule(
  uuid, uuid, public.late_fee_basis, int, bigint, numeric, bigint, int, uuid[], text[], date
) from public, anon;
grant execute on function public.create_late_fee_rule(
  uuid, uuid, public.late_fee_basis, int, bigint, numeric, bigint, int, uuid[], text[], date
) to authenticated;

-- The calculator. Chargeable days = days elapsed since the (holiday/Sunday
-- shifted) due date, minus grace_days — zero until that's positive, per
-- every AC example given.
create or replace function public.compute_late_fee(p_challan_id uuid, p_as_of date default current_date)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_challan         public.fee_challan%rowtype;
  v_rule            public.late_fee_rule%rowtype;
  v_shifted_due     date;
  v_days_late       int;
  v_chargeable_days int;
  v_exempt          boolean;
  v_base_amount     bigint;
  v_raw             bigint;
  v_guard           int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- created_at desc is a deliberate tiebreak, not decoration: two rules
  -- created the same calendar day (a same-day correction is a realistic
  -- case, not an edge case) both have the same effective_from, and
  -- "order by effective_from desc" alone has no defined winner between
  -- them. The most recently created rule is the one meant to be in force.
  select * into v_rule from public.late_fee_rule
   where campus_id = v_challan.campus_id and session_id = v_challan.session_id and effective_from <= p_as_of
   order by effective_from desc, created_at desc
   limit 1;
  if not found then
    return 0::bigint;
  end if;

  select exists (
    select 1 from public.concession_award ca
    join public.concession_scheme cs on cs.id = ca.scheme_id
    where ca.enrolment_id = v_challan.enrolment_id and ca.status = 'approved'
      and ca.effective_from <= p_as_of and ca.effective_to >= p_as_of
      and cs.category = any(v_rule.exempt_concession_categories)
  ) into v_exempt;
  if v_exempt then
    return 0::bigint;
  end if;

  v_shifted_due := v_challan.due_date;
  while v_guard < 14 and (
    extract(dow from v_shifted_due) = 0
    or exists (
      select 1 from public.holiday_calendar
       where tenant_id = v_challan.tenant_id and (campus_id = v_challan.campus_id or campus_id is null)
         and holiday_date = v_shifted_due
    )
  ) loop
    v_shifted_due := v_shifted_due + 1;
    v_guard := v_guard + 1;
  end loop;

  v_days_late := p_as_of - v_shifted_due;
  v_chargeable_days := greatest(0, v_days_late - v_rule.grace_days);
  if v_chargeable_days = 0 then
    return 0::bigint;
  end if;

  if v_rule.basis = 'flat' then
    v_raw := v_rule.amount_paisa;
  elsif v_rule.basis = 'per_day' then
    if v_rule.max_days is not null then
      v_chargeable_days := least(v_chargeable_days, v_rule.max_days);
    end if;
    v_raw := v_chargeable_days::bigint * v_rule.amount_paisa;
  else
    select coalesce(sum(net_paisa), 0) into v_base_amount
      from public.fee_challan_line
     where challan_id = p_challan_id
       and (v_rule.applicable_head_ids is null or fee_head_id = any(v_rule.applicable_head_ids));
    v_raw := round(v_base_amount * v_rule.percentage / 100.0)::bigint;
  end if;

  if v_rule.cap_paisa is not null then
    v_raw := least(v_raw, v_rule.cap_paisa);
  end if;

  return greatest(v_raw, 0::bigint);
end;
$$;

revoke execute on function public.compute_late_fee(uuid, date) from public, anon;
grant execute on function public.compute_late_fee(uuid, date) to authenticated;

alter table public.late_fee_rule enable row level security;
alter table public.holiday_calendar enable row level security;

create policy late_fee_rule_campus_scope on public.late_fee_rule
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy holiday_calendar_campus_scope on public.holiday_calendar
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
