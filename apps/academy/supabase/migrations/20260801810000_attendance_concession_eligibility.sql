-- FR-G17: attendance-linked fee concession eligibility feed.
--
-- A merit-type scheme can require a minimum attendance percentage
-- (concession_scheme.min_attendance_pct). Eligibility is keyed by BILLING
-- month and measured on the PREVIOUS month's attendance, because that is the
-- month that is complete when the challan is generated on the 1st; the
-- nightly refresh therefore settles it before generation can use it.
--
-- The fee side reads a snapshot (attendance_eligibility_flag), never the
-- attendance rows: an Accountant can see the flag and the percentage but not
-- one day of attendance (attendance_day_campus_read now excludes the
-- accountant role). A challan that has been issued is NEVER mutated when the
-- attendance behind it is corrected later; the flip opens an adjustment task
-- for the Accountant instead, because bank challan stubs are reconciled
-- against the issued amount. A student with no attendance data is treated as
-- eligible: withholding money needs evidence, and a missing month is not 0%.
--
-- Challan generation itself is untouched: the concession amount comes from
-- app.fn_plan_line_period_charges (widened below), and the withheld note is
-- stamped by a BEFORE INSERT trigger on fee_challan, which also records the
-- flag the challan used so a later flip can be detected.

alter table public.concession_scheme
  add column if not exists min_attendance_pct numeric(5, 2) check (min_attendance_pct is null or (min_attendance_pct > 0 and min_attendance_pct <= 100));
alter table public.fee_challan add column if not exists note text;

drop policy if exists attendance_day_campus_read on public.attendance_day;
create policy attendance_day_campus_read on public.attendance_day
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'student', 'accountant')
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id = any(app.auth_campus_ids())
    )
  );

create table public.attendance_eligibility_flag (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  enrolment_id   uuid not null references public.enrolment(id) on delete cascade,
  award_id       uuid not null references public.concession_award(id) on delete cascade,
  scheme_id      uuid not null references public.concession_scheme(id) on delete cascade,
  billing_year   smallint not null,
  billing_month  smallint not null check (billing_month between 1 and 12),
  attendance_pct numeric(5, 2),
  required_pct   numeric(5, 2) not null,
  eligible       boolean not null,
  reason_code    text not null check (reason_code in ('meets_threshold', 'below_threshold', 'no_attendance_data')),
  computed_at    timestamptz not null default clock_timestamp(),
  constraint uq_eligibility_award_month unique (award_id, billing_year, billing_month)
);
create index idx_eligibility_scope on public.attendance_eligibility_flag (tenant_id, campus_id, billing_year, billing_month);
create index idx_eligibility_enrolment on public.attendance_eligibility_flag (enrolment_id);
create index idx_eligibility_scheme on public.attendance_eligibility_flag (scheme_id);

create table public.attendance_eligibility_adjustment (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  award_id        uuid not null references public.concession_award(id) on delete cascade,
  billing_year    smallint not null,
  billing_month   smallint not null,
  old_flag        boolean not null,
  new_flag        boolean not null,
  old_pct         numeric(5, 2),
  new_pct         numeric(5, 2),
  challan_id      uuid not null references public.fee_challan(id) on delete cascade,
  status          text not null default 'open' check (status in ('open', 'resolved')),
  created_at      timestamptz not null default now(),
  resolved_by     uuid references auth.users(id),
  resolved_at     timestamptz,
  resolution_note text
);
create unique index uq_eligibility_adjustment_open on public.attendance_eligibility_adjustment (award_id, billing_year, billing_month) where status = 'open';
create index idx_eligibility_adjustment_scope on public.attendance_eligibility_adjustment (tenant_id, campus_id, status);
create index idx_eligibility_adjustment_challan on public.attendance_eligibility_adjustment (challan_id);
create index idx_eligibility_adjustment_enrolment on public.attendance_eligibility_adjustment (enrolment_id);

create trigger attendance_eligibility_adjustment_audit after insert or update or delete on public.attendance_eligibility_adjustment
  for each row execute function app.tg_audit_row();

alter table public.attendance_eligibility_flag enable row level security;
alter table public.attendance_eligibility_adjustment enable row level security;

create policy eligibility_accountant_read on public.attendance_eligibility_flag for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy eligibility_adjustment_read on public.attendance_eligibility_adjustment for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));

create view public.v_attendance_concession_eligibility with (security_invoker = true) as
select f.id, f.tenant_id, f.campus_id, f.enrolment_id, f.award_id, f.scheme_id, f.billing_year, f.billing_month,
       f.attendance_pct, f.required_pct, f.eligible as attendance_eligible, f.reason_code, f.computed_at,
       cs.code as scheme_code, cs.name_en as scheme_name
  from public.attendance_eligibility_flag f
  join public.concession_scheme cs on cs.id = f.scheme_id;
grant select on public.v_attendance_concession_eligibility to authenticated;

create or replace function public.set_scheme_min_attendance(p_scheme_id uuid, p_min_pct numeric default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_min_pct is not null and (p_min_pct <= 0 or p_min_pct > 100) then
    raise exception 'PERCENTAGE_OUT_OF_RANGE' using errcode = '22023';
  end if;
  update public.concession_scheme set min_attendance_pct = p_min_pct where id = p_scheme_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_scheme_min_attendance(uuid, numeric) from public, anon;
grant execute on function public.set_scheme_min_attendance(uuid, numeric) to authenticated;

create or replace function app.fn_eligibility_eval(p_enrolment_id uuid, p_required numeric, p_year int, p_month int)
returns table (pct numeric, eligible boolean, reason_code text)
language sql
stable
set search_path = ''
as $$
  select m.attendance_pct,
         m.attendance_pct is null or m.attendance_pct >= p_required,
         case when m.attendance_pct is null then 'no_attendance_data' when m.attendance_pct >= p_required then 'meets_threshold' else 'below_threshold' end
    from (select 1) d
    left join public.attendance_month_summary m
      on m.enrolment_id = p_enrolment_id
     and m.year = extract(year from (make_date(p_year, p_month, 1) - interval '1 month'))::int
     and m.month = extract(month from (make_date(p_year, p_month, 1) - interval '1 month'))::int;
$$;
revoke execute on function app.fn_eligibility_eval(uuid, numeric, int, int) from public, anon, authenticated;

create or replace function app.fn_eligibility_flag(p_award_id uuid, p_enrolment_id uuid, p_required numeric, p_year int, p_month int)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(
    (select f.eligible from public.attendance_eligibility_flag f where f.award_id = p_award_id and f.billing_year = p_year and f.billing_month = p_month),
    (select e.eligible from app.fn_eligibility_eval(p_enrolment_id, p_required, p_year, p_month) e)
  );
$$;
revoke execute on function app.fn_eligibility_flag(uuid, uuid, numeric, int, int) from public, anon, authenticated;

-- Widened: an award whose scheme has an attendance threshold only contributes
-- while the student is eligible for that billing month.
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
         and (cs.min_attendance_pct is null
              or app.fn_eligibility_flag(ca.id, p_enrolment_id, cs.min_attendance_pct, extract(year from p_period_start)::int, extract(month from p_period_start)::int))
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

-- Printed and portal challans carry the note.
create or replace function app.fn_challan_payload(p_challan_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $$
declare
  v_challan  public.fee_challan%rowtype;
  v_template public.challan_template%rowtype;
  v_student  record;
  v_lines    jsonb;
  v_logo     jsonb;
  v_arrears  jsonb;
begin
  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_template from public.challan_template where campus_id = v_challan.campus_id;
  if v_challan.logo_asset_id is not null then
    select jsonb_build_object('asset_id', id, 'storage_path', storage_path) into v_logo
      from public.branding_asset where id = v_challan.logo_asset_id;
  end if;

  select s.name_en, s.gr_number, cl.name_en as class_name, cs.name as section_name
    into v_student
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
   where e.id = v_challan.enrolment_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'head_name', fh.name_en, 'amount_paisa', fcl.amount_paisa,
           'concession_paisa', fcl.concession_paisa, 'net_paisa', fcl.net_paisa, 'line_type', fcl.line_type
         ) order by fh.code), '[]'::jsonb)
    into v_lines
    from public.fee_challan_line fcl
    join public.fee_head fh on fh.id = fcl.fee_head_id
   where fcl.challan_id = p_challan_id;

  -- Resolved against academic_session for the session NAME, not just the
  -- id: "Arrears (2025-26)" is what makes the carried amount answerable
  -- at the counter without a second lookup.
  select coalesce(jsonb_agg(jsonb_build_object(
           'session_id', src ->> 'session_id',
           'session_name', ses.name,
           'amount_paisa', (src ->> 'amount_paisa')::bigint
         )), '[]'::jsonb)
    into v_arrears
    from jsonb_array_elements(v_challan.arrears_source) src
    left join public.academic_session ses on ses.id = (src ->> 'session_id')::uuid;

  return jsonb_build_object(
    'challan_no', v_challan.challan_no,
    'barcode_value', v_challan.challan_no,
    'billing_period', v_challan.billing_period,
    'issue_date', v_challan.issue_date,
    'due_date', v_challan.due_date,
    'student', jsonb_build_object(
      'name_en', v_student.name_en, 'gr_number', v_student.gr_number,
      'class_name', v_student.class_name, 'section_name', v_student.section_name
    ),
    'bank', jsonb_build_object(
      'bank_name', v_template.bank_name, 'bank_account_title', v_template.bank_account_title,
      'bank_account_no', v_template.bank_account_no, 'footer_note_en', v_template.footer_note_en,
      'footer_note_ur', v_template.footer_note_ur
    ),
    'logo', v_logo,
    'lines', v_lines,
    'gross_paisa', v_challan.gross_paisa,
    'concession_paisa', v_challan.concession_paisa,
    'arrears_paisa', v_challan.arrears_paisa,
    'arrears_source', v_arrears,
    'note', v_challan.note,
    'net_paisa', v_challan.net_paisa,
    'copies', jsonb_build_array('bank', 'school', 'student')
  );
end;
$$;
revoke execute on function app.fn_challan_payload(uuid) from public, anon, authenticated;

create or replace function app.tg_challan_attendance_note()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  r        record;
  v_flag   public.attendance_eligibility_flag%rowtype;
  v_year   int := extract(year from new.billing_period)::int;
  v_month  int := extract(month from new.billing_period)::int;
  v_notes  text[] := '{}';
begin
  for r in
    select ca.id as award_id, cs.id as scheme_id, cs.min_attendance_pct as required, coalesce(initcap(cs.category), cs.name_en) as label
      from public.concession_award ca
      join public.concession_scheme cs on cs.id = ca.scheme_id
     where ca.enrolment_id = new.enrolment_id and ca.status = 'approved' and cs.min_attendance_pct is not null
       and ca.effective_from <= (date_trunc('month', new.billing_period) + interval '1 month - 1 day')::date
       and ca.effective_to >= date_trunc('month', new.billing_period)::date
  loop
    insert into public.attendance_eligibility_flag (tenant_id, campus_id, enrolment_id, award_id, scheme_id, billing_year, billing_month, attendance_pct, required_pct, eligible, reason_code)
    select new.tenant_id, new.campus_id, new.enrolment_id, r.award_id, r.scheme_id, v_year, v_month, e.pct, r.required, e.eligible, e.reason_code
      from app.fn_eligibility_eval(new.enrolment_id, r.required, v_year, v_month) e
    on conflict (award_id, billing_year, billing_month) do nothing;
    select * into v_flag from public.attendance_eligibility_flag where award_id = r.award_id and billing_year = v_year and billing_month = v_month;
    if not v_flag.eligible then
      v_notes := v_notes || format('%s concession withheld: attendance %s%% below required %s%%', r.label, trim_scale(v_flag.attendance_pct)::text, trim_scale(v_flag.required_pct)::text);
    end if;
  end loop;
  if cardinality(v_notes) > 0 then
    new.note := array_to_string(v_notes, '; ');
  end if;
  return new;
end;
$$;
create trigger fee_challan_attendance_note before insert on public.fee_challan
  for each row execute function app.tg_challan_attendance_note();

-- Re-evaluates every threshold award of a campus for one billing month, from
-- the attendance summary as it stands now. A flip against the flag a challan
-- already used opens an adjustment task; the challan is never touched.
create or replace function app.fn_reevaluate_eligibility(p_campus_id uuid, p_year int, p_month int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r        record;
  ev       record;
  v_old    public.attendance_eligibility_flag%rowtype;
  v_challan uuid;
  v_n      int := 0;
  v_flips  int := 0;
  v_tasks  int := 0;
  v_first  date := make_date(p_year, p_month, 1);
  v_last   date := (make_date(p_year, p_month, 1) + interval '1 month - 1 day')::date;
begin
  for r in
    select ca.id as award_id, ca.enrolment_id, ca.tenant_id, ca.campus_id, cs.id as scheme_id, cs.min_attendance_pct as required
      from public.concession_award ca
      join public.concession_scheme cs on cs.id = ca.scheme_id
     where ca.campus_id = p_campus_id and ca.status = 'approved' and cs.min_attendance_pct is not null
       and ca.effective_from <= v_last and ca.effective_to >= v_first
  loop
    v_n := v_n + 1;
    select * into ev from app.fn_eligibility_eval(r.enrolment_id, r.required, p_year, p_month);
    select * into v_old from public.attendance_eligibility_flag where award_id = r.award_id and billing_year = p_year and billing_month = p_month;
    if not found then
      insert into public.attendance_eligibility_flag (tenant_id, campus_id, enrolment_id, award_id, scheme_id, billing_year, billing_month, attendance_pct, required_pct, eligible, reason_code)
      values (r.tenant_id, r.campus_id, r.enrolment_id, r.award_id, r.scheme_id, p_year, p_month, ev.pct, r.required, ev.eligible, ev.reason_code);
      continue;
    end if;

    update public.attendance_eligibility_flag
       set attendance_pct = ev.pct, required_pct = r.required, eligible = ev.eligible, reason_code = ev.reason_code, computed_at = clock_timestamp()
     where id = v_old.id and (attendance_pct is distinct from ev.pct or required_pct <> r.required or eligible <> ev.eligible);

    if v_old.eligible <> ev.eligible then
      v_flips := v_flips + 1;
      select c.id into v_challan from public.fee_challan c
       where c.enrolment_id = r.enrolment_id and c.billing_period between v_first and v_last and c.status <> 'cancelled' and c.deleted_at is null
       limit 1;
      if v_challan is not null then
        insert into public.attendance_eligibility_adjustment (tenant_id, campus_id, enrolment_id, award_id, billing_year, billing_month, old_flag, new_flag, old_pct, new_pct, challan_id)
        values (r.tenant_id, r.campus_id, r.enrolment_id, r.award_id, p_year, p_month, v_old.eligible, ev.eligible, v_old.attendance_pct, ev.pct, v_challan)
        on conflict (award_id, billing_year, billing_month) where status = 'open'
        do update set new_flag = excluded.new_flag, new_pct = excluded.new_pct;
        update public.attendance_eligibility_adjustment
           set status = 'resolved', resolved_at = now(), resolution_note = 'The flag went back to what the challan used'
         where award_id = r.award_id and billing_year = p_year and billing_month = p_month and status = 'open' and new_flag = old_flag;
        v_tasks := v_tasks + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('evaluated', v_n, 'flipped', v_flips, 'tasks', v_tasks);
end;
$$;
revoke execute on function app.fn_reevaluate_eligibility(uuid, int, int) from public, anon, authenticated;

create or replace function public.refresh_attendance_eligibility(p_campus_id uuid, p_year int, p_month int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev date := make_date(p_year, p_month, 1) - interval '1 month';
begin
  if app.auth_tenant_id() is not null then
    if app.auth_role() not in ('owner', 'super_admin', 'principal') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
    if app.auth_role() = 'principal' and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;
  if p_month not between 1 and 12 then
    raise exception 'MONTH_OUT_OF_RANGE' using errcode = '22023';
  end if;
  perform public.compute_month_attendance(p_campus_id, extract(year from v_prev)::int, extract(month from v_prev)::int);
  return app.fn_reevaluate_eligibility(p_campus_id, p_year, p_month);
end;
$$;
revoke execute on function public.refresh_attendance_eligibility(uuid, int, int) from public, anon;
grant execute on function public.refresh_attendance_eligibility(uuid, int, int) to authenticated, service_role;

-- Nightly, for the current Karachi month: the run at 03:00 on the 1st settles
-- the new month's flags before challan generation, and every other night picks
-- up attendance corrections. Each tenant is processed under its own claims so
-- working_days_between sees that tenant's holidays.
create or replace function public.refresh_attendance_eligibility_all()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_prev  text := current_setting('request.jwt.claims', true);
  v_today date := app.fn_karachi_today();
  t       record;
  v_n     int := 0;
begin
  for t in
    select distinct c.tenant_id, c.id as campus_id
      from public.campus c
      join public.concession_award ca on ca.campus_id = c.id and ca.status = 'approved'
      join public.concession_scheme cs on cs.id = ca.scheme_id and cs.min_attendance_pct is not null
  loop
    perform set_config('request.jwt.claims', json_build_object('tenant_id', t.tenant_id, 'app_role', 'owner', 'campus_ids', json_build_array(t.campus_id))::text, true);
    perform public.refresh_attendance_eligibility(t.campus_id, extract(year from v_today)::int, extract(month from v_today)::int);
    v_n := v_n + 1;
  end loop;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_n;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function public.refresh_attendance_eligibility_all() from public, anon, authenticated;
grant execute on function public.refresh_attendance_eligibility_all() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('eligibility_refresh', '0 22 * * *', 'select public.refresh_attendance_eligibility_all();');
  end if;
exception
  when others then null;
end;
$$;

create or replace function public.resolve_eligibility_adjustment(p_task_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.attendance_eligibility_adjustment
     set status = 'resolved', resolved_by = (select auth.uid()), resolved_at = now(), resolution_note = nullif(btrim(p_note), '')
   where id = p_task_id and tenant_id = app.auth_tenant_id() and status = 'open'
     and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()));
  if not found then
    raise exception 'TASK_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.resolve_eligibility_adjustment(uuid, text) from public, anon;
grant execute on function public.resolve_eligibility_adjustment(uuid, text) to authenticated;
