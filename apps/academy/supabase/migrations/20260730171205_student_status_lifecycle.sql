-- FR-C12: student status moves only along legal paths, with a reason, an
-- effective date, and a full history row per transition.
--
-- Scope cuts:
--   * "Transfer requires an issued Transfer Certificate unless a Principal
--     waives it" — Module T (Certificates) doesn't exist, so there is no
--     real TC-issued flag to check. The document requirement is modelled
--     (student_status_transition.requires_document) and the waive path is
--     Principal-gated and reason-recorded, but it always waives (nothing
--     to NOT waive against yet).
--   * The daily "on_leave > 60 days raises a review task" job needs both a
--     task/notification destination (doesn't exist) and pg_cron (not
--     enabled locally). fn_find_overdue_leave_students() does the actual
--     detection query — correct and tested — just not wired to a schedule
--     or a task inbox.
--   * Effective-dated status not yet counting/excluding in attendance
--     percentages is Module G's (Attendance) concern once it exists; this
--     migration's job is only to record the effective_date correctly.

create type public.status_reason_code as enum (
  'admission', 'promotion', 'transfer_out', 'transfer_in', 'graduation',
  'long_absence', 'disciplinary', 'fee_default', 'readmission', 'medical', 'relocation', 'other'
);

create table public.student_status_history (
  id             uuid primary key default gen_random_uuid(),
  student_id     uuid not null references public.student(id) on delete cascade,
  from_status    public.student_status not null,
  to_status      public.student_status not null,
  reason_code    public.status_reason_code not null,
  reason_note    text,
  effective_date date not null,
  changed_by     uuid references public.app_user(user_id),
  changed_at     timestamptz not null default now()
);

create index idx_student_status_history_student on public.student_status_history (student_id, effective_date desc);

-- The legal-transition matrix, seeded as data rather than hardcoded in the
-- function, so a future role/document requirement change is a data update,
-- not a redeploy.
create table public.student_status_transition (
  from_status          public.student_status not null,
  to_status            public.student_status not null,
  requires_role        public.app_role,
  requires_document    boolean not null default false,
  -- Set only on reactivation from a terminal status: "only readmission may
  -- reactivate" means the reason code itself is the gate, not just a legal
  -- status pair — otherwise any reason (e.g. 'other') could reactivate a
  -- graduated student, which is exactly what the AC forbids.
  requires_reason_code public.status_reason_code,
  primary key (from_status, to_status)
);

insert into public.student_status_transition (from_status, to_status, requires_role, requires_document, requires_reason_code) values
  ('active',      'inactive',    null,        false, null),
  ('active',      'on_leave',    null,        false, null),
  ('on_leave',    'active',      null,        false, null),
  ('on_leave',    'struck_off',  'principal', false, null),
  ('active',      'transferred', 'principal', true,  null),
  ('active',      'struck_off',  'principal', false, null),
  ('active',      'graduated',   'principal', false, null),
  ('active',      'expelled',    'principal', false, null),
  ('inactive',    'active',      null,        false, null),
  ('graduated',   'active',      'principal', false, 'readmission'),
  ('struck_off',  'active',      'principal', false, 'readmission'),
  ('transferred', 'active',      'principal', false, 'readmission');

create or replace function public.fn_change_student_status(
  p_student_id     uuid,
  p_to_status      public.student_status,
  p_reason_code    public.status_reason_code,
  p_effective_date date default current_date,
  p_reason_note    text default null,
  p_waive_document boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student    public.student%rowtype;
  v_transition public.student_status_transition%rowtype;
begin
  select * into v_student from public.student where id = p_student_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_student.tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_transition from public.student_status_transition
   where from_status = v_student.status and to_status = p_to_status;
  if not found then
    raise exception 'ILLEGAL_STATUS_TRANSITION'
      using errcode = '23514', detail = format('from=%s to=%s', v_student.status, p_to_status);
  end if;

  if v_transition.requires_role is not null
     and app.auth_role() <> v_transition.requires_role::text
     and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_transition.requires_reason_code is not null and p_reason_code <> v_transition.requires_reason_code then
    raise exception 'ILLEGAL_STATUS_TRANSITION'
      using errcode = '23514', detail = format('reason_code %s required for this transition', v_transition.requires_reason_code);
  end if;

  if v_transition.requires_document and not p_waive_document then
    raise exception 'DOCUMENT_REQUIRED'
      using errcode = '23514',
            detail = 'a Principal may waive this with p_waive_document => true, which is itself recorded on the history row';
  end if;

  insert into public.student_status_history (
    student_id, from_status, to_status, reason_code, reason_note, effective_date, changed_by
  ) values (
    p_student_id, v_student.status, p_to_status, p_reason_code,
    case when v_transition.requires_document and p_waive_document
         then coalesce(p_reason_note, '') || ' [document requirement waived]'
         else p_reason_note end,
    p_effective_date, auth.uid()
  );

  update public.student set status = p_to_status where id = p_student_id;
end;
$$;

revoke execute on function public.fn_change_student_status(
  uuid, public.student_status, public.status_reason_code, date, text, boolean
) from public, anon;
grant execute on function public.fn_change_student_status(
  uuid, public.student_status, public.status_reason_code, date, text, boolean
) to authenticated;

create or replace function public.fn_find_overdue_leave_students()
returns table(student_id uuid, days_on_leave int)
language sql
stable
security definer
set search_path = ''
as $$
  select s.id, (current_date - h.effective_date)::int
    from public.student s
    join lateral (
      select effective_date from public.student_status_history
       where student_id = s.id and to_status = 'on_leave'
       order by effective_date desc
       limit 1
    ) h on true
   where s.status = 'on_leave'
     and s.tenant_id = app.auth_tenant_id()
     and current_date - h.effective_date > 60;
$$;

revoke execute on function public.fn_find_overdue_leave_students() from public, anon;
grant execute on function public.fn_find_overdue_leave_students() to authenticated;

alter table public.student_status_history enable row level security;
alter table public.student_status_transition enable row level security;

create policy student_status_history_campus_scope on public.student_status_history
  for select to authenticated
  using (
    student_id in (
      select id from public.student
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

create policy student_status_transition_tenant_read on public.student_status_transition
  for select to authenticated
  using (true);
