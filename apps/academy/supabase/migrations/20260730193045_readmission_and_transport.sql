-- FR-C13 (readmission under the original GR number) and FR-C07 (transport
-- opt-in), shipped together — unrelated to each other, but both are
-- small additions on top of already-shipped foundations (C13 reuses
-- fn_change_student_status and enrol_student wholesale; C07 is a
-- standalone table+view) and neither is big enough to be its own batch.
--
-- Scope cuts:
--   * C13's readmission-fee gate ("blocked exactly as in FR-B17") needs
--     FR-B17/Fees, which doesn't exist — fn_readmit_student has no
--     payment_id parameter and no fee check.
--   * C07's route_id/stop_id ship nullable and nothing binds them — the
--     FR's own Notes say this is deliberate: Phase 5 (Transport
--     Operations) hasn't landed, and the pickup area captured at
--     admission is what matters until it does.

-- 'left' predates the FR-C12 enum extension (transferred/struck_off/
-- on_leave) and never got its own path back to active — added here as a
-- data-only row on the existing matrix table, not by editing the already-
-- shipped C12 migration.
insert into public.student_status_transition (from_status, to_status, requires_role, requires_document, requires_reason_code)
values ('left', 'active', 'principal', false, 'readmission');

create or replace function public.fn_find_readmission_candidates(
  p_b_form_no text default null, p_name_en text default null, p_dob date default null
)
returns table(student_id uuid, gr_number text, name_en text, status public.student_status, no_readmission_flag boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select id, gr_number, name_en, status, no_readmission_flag
    from public.student
   where tenant_id = app.auth_tenant_id()
     and status <> 'active'
     and (
       (p_b_form_no is not null and b_form_no = app.fn_normalize_pk_id(p_b_form_no))
       or (p_name_en is not null and p_dob is not null and lower(name_en) = lower(p_name_en) and dob = p_dob)
     );
$$;

revoke execute on function public.fn_find_readmission_candidates(text, text, date) from public, anon;
grant execute on function public.fn_find_readmission_candidates(text, text, date) to authenticated;

create or replace function public.fn_readmit_student(p_student_id uuid, p_section_id uuid, p_override_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student      public.student%rowtype;
  v_enrolment_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_student from public.student where id = p_student_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_student.no_readmission_flag then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'READMISSION_BLOCKED'
        using errcode = '42501', detail = 'flagged no_readmission — only an Owner/Director may override, with a recorded reason';
    end if;
    if p_override_reason is null then
      raise exception 'OVERRIDE_REASON_REQUIRED' using errcode = '23514';
    end if;
  end if;

  -- Reactivates the SAME student row under the SAME GR number — that
  -- continuity across the gap is the entire point of a permanent GR
  -- (FR-C01). fn_change_student_status's own matrix (from FR-C12) is what
  -- actually enforces the role + reason-code gate here.
  perform public.fn_change_student_status(
    p_student_id, 'active', 'readmission', current_date,
    case when v_student.no_readmission_flag then coalesce(p_override_reason, '') || ' [no_readmission override]' else p_override_reason end
  );

  v_enrolment_id := public.enrol_student(p_section_id, p_student_id);

  return v_enrolment_id;
end;
$$;

revoke execute on function public.fn_readmit_student(uuid, uuid, text) from public, anon;
grant execute on function public.fn_readmit_student(uuid, uuid, text) to authenticated;

-- ── C07: student_transport ───────────────────────────────────────────

create type public.transport_direction as enum ('pickup', 'drop', 'both');

create table public.student_transport (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  student_id  uuid not null references public.student(id) on delete cascade,
  session_id  uuid not null references public.academic_session(id) on delete cascade,
  opt_in      boolean not null default true,
  direction   public.transport_direction not null default 'both',
  pickup_area text,
  route_id    uuid,
  stop_id     uuid,
  from_date   date not null default current_date,
  to_date     date,
  fee_slab_id uuid,
  created_at  timestamptz not null default now()
);

create index idx_transport_unrouted on public.student_transport (campus_id, session_id) where opt_in and route_id is null and to_date is null;
create index idx_transport_student_session on public.student_transport (student_id, session_id);

create trigger student_transport_audit after insert or update or delete on public.student_transport
  for each row execute function app.tg_audit_row();

create or replace function public.fn_set_transport_optin(
  p_student_id uuid, p_session_id uuid, p_opt_in boolean,
  p_direction public.transport_direction default 'both', p_pickup_area text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student   public.student%rowtype;
  v_id        uuid;
  v_had_open  boolean;
  v_month_end date;
  v_new_from  date;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_student from public.student where id = p_student_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select exists(
    select 1 from public.student_transport
     where student_id = p_student_id and session_id = p_session_id and to_date is null
  ) into v_had_open;

  v_month_end := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;

  if v_had_open then
    -- Billed through the end of the month the change lands in — never
    -- retroactively, per the AC (opt-out on 20 March still bills March).
    update public.student_transport
       set to_date = v_month_end
     where student_id = p_student_id and session_id = p_session_id and to_date is null;
    v_new_from := v_month_end + 1;
  else
    v_new_from := current_date;
  end if;

  insert into public.student_transport (tenant_id, campus_id, student_id, session_id, opt_in, direction, pickup_area, from_date)
  values (app.auth_tenant_id(), v_student.campus_id, p_student_id, p_session_id, p_opt_in, p_direction, p_pickup_area, v_new_from)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.fn_set_transport_optin(uuid, uuid, boolean, public.transport_direction, text) from public, anon;
grant execute on function public.fn_set_transport_optin(uuid, uuid, boolean, public.transport_direction, text) to authenticated;

alter table public.student_transport enable row level security;

create policy transport_read_campus on public.student_transport
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create view public.v_unrouted_transport
with (security_invoker = true) as
select st.id, st.student_id, s.name_en, st.campus_id, st.session_id, st.pickup_area, st.direction
  from public.student_transport st
  join public.student s on s.id = st.student_id
 where st.opt_in and st.route_id is null and st.to_date is null;
