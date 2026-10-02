-- FR-G11: attendance correction approval with immutable audit.
--
--   * Two tables, not one: attendance_audit must be genuinely append-only
--     (the FR's own note: an RLS USING(false) policy alone isn't enough,
--     since the table owner bypasses RLS — this migration also runs a
--     BEFORE UPDATE/DELETE trigger that raises unconditionally, the same
--     belt-and-suspenders pattern fee_ledger's own immutability trigger
--     uses). An append-only table can't also host a "pending -> approved"
--     status transition, so the mutable half of the workflow — the
--     request itself, and its decision — lives in a separate
--     attendance_correction_request row; approve_attendance_correction()
--     both decides that row AND inserts exactly one new, permanent
--     attendance_audit row. source_correction_id is how an audit row
--     traces back to the request that produced it.
--   * A correction request is exactly how attendance_day gets edited
--     AFTER FR-G09's lock — approval is the explicit, audited override
--     path, so approve_attendance_correction() intentionally never calls
--     is_attendance_locked().
--   * AC3's "flagged stale and recomputed on the next run" describes
--     FR-G14 (monthly attendance summary), not yet built. This migration
--     adds attendance_monthly_summary now, in exactly the minimal shape
--     FR-G14 will need, and approve_attendance_correction() already
--     flags a *finalized* row stale — a no-op today since nothing
--     inserts into this table yet, but the exact hook FR-G14's own
--     finalize function will need to leave alone. Same "reference schema
--     now, the function that actually populates it later" pattern this
--     session used for FR-K06/K11 before Storage existed.

alter table public.attendance_day add column corrected boolean not null default false;

create type public.attendance_correction_status as enum ('pending', 'approved', 'rejected');

create table public.attendance_correction_request (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  attendance_date date not null,
  old_status      public.student_attendance_status,
  new_status      public.student_attendance_status not null,
  reason          text not null,
  status          public.attendance_correction_status not null default 'pending',
  requested_by    uuid references public.app_user(user_id),
  requested_at    timestamptz not null default clock_timestamp(),
  decided_by      uuid references public.app_user(user_id),
  decided_at      timestamptz,
  decision_note   text,
  constraint chk_correction_reason_len check (length(btrim(reason)) >= 10)
);

create index idx_att_correction_pending on public.attendance_correction_request (campus_id, status) where status = 'pending';

create trigger attendance_correction_request_audit after insert or update or delete on public.attendance_correction_request
  for each row execute function app.tg_audit_row();

-- bigserial, per the FR's own spec — this table is queried and scanned,
-- never looked up by a client-supplied id the way a uuid guards against.
create table public.attendance_audit (
  id                  bigserial primary key,
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  session_id          uuid not null references public.academic_session(id) on delete cascade,
  enrolment_id        uuid not null references public.enrolment(id) on delete cascade,
  attendance_date     date not null,
  old_status          public.student_attendance_status,
  new_status          public.student_attendance_status not null,
  reason              text,
  requested_by        uuid references public.app_user(user_id),
  approved_by         uuid references public.app_user(user_id),
  approved_at         timestamptz not null default clock_timestamp(),
  source_correction_id uuid references public.attendance_correction_request(id)
);

create index idx_att_audit_enrol on public.attendance_audit (enrolment_id, attendance_date);

create or replace function app.tg_attendance_audit_no_mutate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'ATTENDANCE_AUDIT_IMMUTABLE' using errcode = '42501';
end;
$$;

create trigger attendance_audit_no_mutate before update or delete on public.attendance_audit
  for each row execute function app.tg_attendance_audit_no_mutate();

-- FR-G14's own table — not populated by anything yet. Present only so
-- approve_attendance_correction() has a real row shape to flag stale.
create table public.attendance_monthly_summary (
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  session_id    uuid not null references public.academic_session(id) on delete cascade,
  enrolment_id  uuid not null references public.enrolment(id) on delete cascade,
  year          smallint not null,
  month         smallint not null check (month between 1 and 12),
  present_days  int not null default 0,
  absent_days   int not null default 0,
  late_days     int not null default 0,
  half_days     int not null default 0,
  finalized_at  timestamptz,
  stale         boolean not null default false,
  primary key (enrolment_id, year, month)
);

create or replace function public.request_attendance_correction(
  p_enrolment_id uuid, p_attendance_date date, p_new_status public.student_attendance_status, p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_enrol     public.enrolment%rowtype;
  v_day       public.attendance_day%rowtype;
  v_id        uuid;
begin
  select * into v_enrol from public.enrolment where id = p_enrolment_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    if app.auth_role() <> 'class_teacher' or not exists (
      select 1 from public.section_class_teacher
       where section_id = v_enrol.section_id and staff_id = auth.uid() and validity @> p_attendance_date
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select * into v_day from public.attendance_day where enrolment_id = p_enrolment_id and attendance_date = p_attendance_date;

  insert into public.attendance_correction_request (
    tenant_id, campus_id, session_id, enrolment_id, attendance_date, old_status, new_status, reason, requested_by
  ) values (
    v_tenant_id, v_enrol.campus_id, v_enrol.session_id, p_enrolment_id, p_attendance_date, v_day.status, p_new_status, p_reason, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.request_attendance_correction(uuid, date, public.student_attendance_status, text) from public, anon;
grant execute on function public.request_attendance_correction(uuid, date, public.student_attendance_status, text) to authenticated;

-- AC1: exactly one attendance_audit row per approval; attendance_day is
-- updated and marked corrected regardless of whether the date is
-- currently locked — approval IS the authorized way past the lock.
create or replace function public.approve_attendance_correction(p_correction_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_req       public.attendance_correction_request%rowtype;
  v_old       public.student_attendance_status;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_req from public.attendance_correction_request where id = p_correction_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CORRECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'CORRECTION_NOT_PENDING' using errcode = '55000';
  end if;

  select status into v_old from public.attendance_day where enrolment_id = v_req.enrolment_id and attendance_date = v_req.attendance_date;
  if not found then
    raise exception 'ATTENDANCE_DAY_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.attendance_day
     set status = v_req.new_status, corrected = true
   where enrolment_id = v_req.enrolment_id and attendance_date = v_req.attendance_date;

  insert into public.attendance_audit (
    tenant_id, campus_id, session_id, enrolment_id, attendance_date, old_status, new_status, reason,
    requested_by, approved_by, source_correction_id
  ) values (
    v_tenant_id, v_req.campus_id, v_req.session_id, v_req.enrolment_id, v_req.attendance_date, v_old, v_req.new_status, v_req.reason,
    v_req.requested_by, auth.uid(), v_req.id
  );

  update public.attendance_correction_request
     set status = 'approved', decided_by = auth.uid(), decided_at = clock_timestamp(), decision_note = p_note
   where id = p_correction_id;

  -- AC3's hook: a no-op today (nothing finalizes a summary row yet).
  update public.attendance_monthly_summary
     set stale = true
   where enrolment_id = v_req.enrolment_id
     and year = extract(year from v_req.attendance_date)::smallint
     and month = extract(month from v_req.attendance_date)::smallint
     and finalized_at is not null;
end;
$$;

revoke execute on function public.approve_attendance_correction(uuid, text) from public, anon;
grant execute on function public.approve_attendance_correction(uuid, text) to authenticated;

create or replace function public.reject_attendance_correction(p_correction_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_note, ''))) < 10 then
    raise exception 'NOTE_TOO_SHORT' using errcode = '23514';
  end if;

  update public.attendance_correction_request
     set status = 'rejected', decided_by = auth.uid(), decided_at = clock_timestamp(), decision_note = p_note
   where id = p_correction_id and tenant_id = v_tenant_id and status = 'pending';

  if not found then
    raise exception 'CORRECTION_NOT_PENDING' using errcode = '55000';
  end if;
end;
$$;

revoke execute on function public.reject_attendance_correction(uuid, text) from public, anon;
grant execute on function public.reject_attendance_correction(uuid, text) to authenticated;

alter table public.attendance_correction_request enable row level security;
alter table public.attendance_audit enable row level security;
alter table public.attendance_monthly_summary enable row level security;

create policy attendance_correction_campus_read on public.attendance_correction_request
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- AC2: select only — no INSERT/UPDATE/DELETE policy exists for
-- authenticated at all, so even a super_admin's own session can never
-- write here directly; the only writer is the SECURITY DEFINER function
-- above, and the BEFORE trigger blocks every UPDATE/DELETE regardless of
-- who or what issues it.
create policy att_audit_select_campus on public.attendance_audit
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy attendance_summary_campus_read on public.attendance_monthly_summary
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
