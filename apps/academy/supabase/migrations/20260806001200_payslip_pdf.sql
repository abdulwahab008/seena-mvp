-- FR-L08: itemised, bilingual payslip PDF for every employee on a locked payroll run.
--
-- The PDF itself is rendered by the app (the same Chromium seam and Nastaliq font the staff
-- certificates use); this migration is the ledger and the access rules around it.
--
--  * payslip: one row per stored file. A regeneration never overwrites: it adds version N+1 and
--    the earlier file stays. Identical bytes (the render is deterministic) add no version.
--  * Only a locked or paid run has payslips. The run check lives here, not only in the route.
--  * Who reads a payslip is the rule payroll lines already use, app.fn_payroll_line_visible():
--    owner, super admin, HR manager and accountant for their school, and the employee themself.
--    The private `payslips` bucket repeats it per file, with the employee id in the file name, so a
--    signed URL for someone else's file does not resolve.
--  * An employee asking for another employee's payslip is refused by the route, which then calls
--    record_payslip_denied(). The attempt lands in audit_log through the audit trigger, in a call of
--    its own because the refusal itself would roll an insert back.

create table public.payslip (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  run_line_id   uuid not null references public.payroll_run_line(id) on delete cascade,
  staff_id      uuid not null references public.staff(id) on delete cascade,
  version       int not null check (version >= 1),
  storage_path  text not null,
  sha256        text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  generated_by  uuid references auth.users(id),
  generated_at  timestamptz not null default now(),
  unique (run_line_id, version)
);

create index idx_payslip_staff on public.payslip (staff_id, generated_at desc);
create index idx_payslip_tenant_campus on public.payslip (tenant_id, campus_id);

create table public.payslip_denied_access (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  payslip_id    uuid not null,
  attempted_by  uuid,
  attempted_at  timestamptz not null default clock_timestamp()
);

create index idx_payslip_denied_tenant on public.payslip_denied_access (tenant_id, attempted_at desc);

create trigger payslip_audit after insert or update or delete on public.payslip
  for each row execute function app.tg_audit_row();
create trigger payslip_denied_access_audit after insert on public.payslip_denied_access
  for each row execute function app.tg_audit_row();

alter table public.payslip enable row level security;
alter table public.payslip_denied_access enable row level security;

create policy payslip_read on public.payslip
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_payroll_line_visible(run_line_id));

create policy payslip_denied_access_read on public.payslip_denied_access
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner'));

revoke insert, update, delete on public.payslip from authenticated, anon;
revoke insert, update, delete on public.payslip_denied_access from authenticated, anon;

-- ── the private bucket ───────────────────────────────────────────────────────────────────
-- Path: <tenant_id>/<run_id>/<employee_id>-v<version>.pdf

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payslips', 'payslips', false, 2097152, array['application/pdf'])
on conflict (id) do nothing;

drop policy if exists payslip_hr_read on storage.objects;
create policy payslip_hr_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'payslips'
    and split_part(name, '/', 1) = app.auth_tenant_id()::text
    and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
  );

drop policy if exists payslip_self_read on storage.objects;
create policy payslip_self_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'payslips'
    and exists (
      select 1 from public.staff s
       where s.user_id = (select auth.uid())
         and s.tenant_id::text = split_part(name, '/', 1)
         and s.id::text = left(split_part(name, '/', 3), 36)
    )
  );

-- ── the lines of a run that may have payslips ────────────────────────────────────────────

create or replace function public.payslip_run_lines(p_run_id uuid)
returns table (line_id uuid, staff_id uuid)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_run public.payroll_run%rowtype;
begin
  select * into v_run from public.payroll_run where id = p_run_id;
  if not found or v_run.tenant_id is distinct from app.auth_tenant_id() then
    raise exception 'RUN_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_payroll_access(array['super_admin', 'owner', 'hr_manager', 'accountant'], v_run.tenant_id, v_run.campus_id);
  if v_run.status not in ('locked', 'paid') then
    raise exception 'run_not_locked' using errcode = '55000';
  end if;

  return query
    select l.id, l.staff_id from public.payroll_run_line l where l.payroll_run_id = p_run_id order by l.id;
end;
$$;

-- ── everything the payslip prints ────────────────────────────────────────────────────────

create or replace function public.payslip_payload(p_run_line_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_line    public.payroll_run_line%rowtype;
  v_run     public.payroll_run%rowtype;
  v_staff   public.staff%rowtype;
  v_tenant  public.tenant%rowtype;
  v_desig   text;
  v_campus  text;
  v_fy      date;
  v_ytd_tax bigint;
  v_loan    bigint;
  v_earn    jsonb;
begin
  if not app.fn_payroll_line_visible(p_run_line_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_line from public.payroll_run_line where id = p_run_line_id;
  select * into v_run from public.payroll_run where id = v_line.payroll_run_id;
  if v_run.status not in ('locked', 'paid') then
    raise exception 'run_not_locked' using errcode = '55000';
  end if;

  select * into v_staff from public.staff where id = v_line.staff_id;
  select * into v_tenant from public.tenant where id = v_run.tenant_id;
  select d.name_en into v_desig from public.designation d where d.id = v_staff.designation_id;
  select c.name into v_campus from public.campus c where c.id = v_run.campus_id;

  -- Pakistan's tax year runs July to June.
  v_fy := make_date(
    extract(year from v_run.period_month)::int - case when extract(month from v_run.period_month) < 7 then 1 else 0 end,
    7, 1
  );

  select coalesce(sum(l.tax_withholding_paisa), 0) into v_ytd_tax
    from public.payroll_run_line l
    join public.payroll_run r on r.id = l.payroll_run_id
   where l.staff_id = v_line.staff_id
     and r.status in ('locked', 'paid')
     and r.period_month >= v_fy and r.period_month <= v_run.period_month;

  select coalesce(sum(sl.principal_paisa - sl.total_repaid_paisa), 0) into v_loan
    from public.staff_loan sl
   where sl.staff_id = v_line.staff_id and sl.status in ('active', 'paused');

  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name_en, 'amount_paisa', c.amount_paisa) order by c.code), '[]'::jsonb)
    into v_earn
    from public.payroll_run_line_component c
   where c.line_id = p_run_line_id and c.component_type = 'earning';

  return jsonb_build_object(
    'school_name', v_tenant.name,
    'school_name_ur', v_tenant.name_ur,
    'campus_name', v_campus,
    'period_month', v_run.period_month,
    'staff_name', v_staff.full_name,
    'staff_name_ur', v_staff.full_name_ur,
    'employee_code', v_staff.employee_code,
    'designation', v_desig,
    'payable_days', v_line.payable_days,
    'unpaid_days', v_line.unpaid_days,
    'earnings', v_earn,
    'gross_paisa', v_line.gross_paisa,
    'deductions', jsonb_build_array(
      jsonb_build_object('key', 'attendance', 'amount_paisa', v_line.attendance_deduction_paisa),
      jsonb_build_object('key', 'tax', 'amount_paisa', v_line.tax_withholding_paisa),
      jsonb_build_object('key', 'loan', 'amount_paisa', v_line.loan_recovery_paisa),
      jsonb_build_object('key', 'other', 'amount_paisa', v_line.other_deductions_paisa)
    ),
    'total_deductions_paisa', v_line.attendance_deduction_paisa + v_line.tax_withholding_paisa + v_line.loan_recovery_paisa + v_line.other_deductions_paisa,
    'net_paisa', v_line.net_paisa,
    'net_in_words', public.amount_in_words(v_line.net_paisa),
    'loan_outstanding_paisa', v_loan,
    'ytd_tax_paisa', v_ytd_tax,
    'tax_year_start', v_fy,
    'tenant_id', v_run.tenant_id,
    'campus_id', v_run.campus_id,
    'run_id', v_run.id,
    'staff_id', v_line.staff_id,
    'run_locked_at', v_run.locked_at
  );
end;
$$;

-- ── the ledger writes, service role only ─────────────────────────────────────────────────

create or replace function public.register_payslip(p_run_line_id uuid, p_version int, p_storage_path text, p_sha256 text, p_generated_by uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_line public.payroll_run_line%rowtype;
  v_run  public.payroll_run%rowtype;
  v_id   uuid;
begin
  select * into v_line from public.payroll_run_line where id = p_run_line_id;
  if not found then
    raise exception 'LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_run from public.payroll_run where id = v_line.payroll_run_id;
  if v_run.status not in ('locked', 'paid') then
    raise exception 'run_not_locked' using errcode = '55000';
  end if;

  insert into public.payslip (tenant_id, campus_id, run_line_id, staff_id, version, storage_path, sha256, generated_by)
  values (v_run.tenant_id, v_run.campus_id, p_run_line_id, v_line.staff_id, p_version, p_storage_path, lower(p_sha256), p_generated_by)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.record_payslip_denied(p_payslip_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null then
    return;
  end if;
  insert into public.payslip_denied_access (tenant_id, payslip_id, attempted_by)
  values (app.auth_tenant_id(), p_payslip_id, auth.uid());
end;
$$;

revoke execute on function public.payslip_run_lines(uuid) from public, anon;
revoke execute on function public.payslip_payload(uuid) from public, anon;
revoke execute on function public.register_payslip(uuid, int, text, text, uuid) from public, anon, authenticated;
revoke execute on function public.record_payslip_denied(uuid) from public, anon;
grant execute on function public.payslip_run_lines(uuid) to authenticated;
grant execute on function public.payslip_payload(uuid) to authenticated;
grant execute on function public.register_payslip(uuid, int, text, text, uuid) to service_role;
grant execute on function public.record_payslip_denied(uuid) to authenticated;
