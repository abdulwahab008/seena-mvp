-- Security hardening: close cross-tenant authorization gaps found by
-- auditing every SECURITY DEFINER function that loads a row by a bare
-- p_*_id parameter. Because these functions run as SECURITY DEFINER, they
-- bypass RLS entirely — a tenant_id check inside the function body is the
-- ONLY thing standing between a caller and reading or mutating another
-- tenant's data by guessing or otherwise obtaining a UUID. Two shapes of
-- the same gap turned up:
--
--   (a) a row is loaded by bare id with no tenant_id check at all before
--       its fields (campus_id, session_id, staff_id, tenant_id itself...)
--       get used to write further rows;
--   (b) the "owner/super_admin skip the narrower campus_ids check" branch,
--       used throughout this schema so leadership roles aren't scoped to
--       one campus, never separately verifies the target campus/session/
--       class_level belongs to their OWN tenant — it just skips the check
--       entirely, so an owner could reach across tenants.
--
-- Every fix below is additive and minimal: create-or-replace with the
-- SAME signature, folding a tenant_id comparison into an existing lookup
-- so it lands on that lookup's EXISTING not-found error rather than
-- inventing a new one. No same-tenant caller's behavior changes — the
-- added condition is always true for a real, same-tenant reference.
-- Deliberately NOT touched (flagged separately, not fixed here, because
-- fixing them would change same-tenant behavior, which is out of scope
-- for a tenant-isolation patch):
--   * create_staff/create_enquiry/create_section/upsert_class_subject
--     still don't scope non-owner roles to their own campus_ids beyond
--     what they already did — only the owner/super_admin cross-TENANT
--     gap is closed here.
--   * fn_respond_to_offer has no role check at all (any authenticated
--     user, any role) — likely deliberate groundwork for a not-yet-built
--     guardian/parent portal response flow, where no staff app_role would
--     apply anyway. Only its cross-tenant gap is closed here; adding a
--     role check is a product decision this migration doesn't make.

-- ── admissions_pipeline.sql: fn_submit_application, fn_issue_offer,
--    fn_extend_offer, fn_respond_to_offer, fn_reinstate_offer ───────────

create or replace function public.fn_submit_application(
  p_enquiry_id uuid, p_group_applied public.academic_group default null,
  p_prev_school text default null, p_prev_class_passed text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_ordinal smallint;
  v_group   public.academic_group;
  v_seq     int;
  v_app_no  text;
  v_app_id  uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ordinal into v_ordinal from public.class_level where id = v_enquiry.class_applied_id;

  if v_ordinal between 10 and 13 then
    if p_group_applied is null then
      raise exception 'Group is required for classes 9-12' using errcode = '23514';
    end if;
    v_group := p_group_applied;
  else
    v_group := null;
  end if;

  insert into public.application_no_counter (campus_id, session_id)
  values (v_enquiry.campus_id, v_enquiry.session_id)
  on conflict (campus_id, session_id) do nothing;

  update public.application_no_counter
     set next_seq = next_seq + 1
   where campus_id = v_enquiry.campus_id and session_id = v_enquiry.session_id
  returning next_seq - 1 into v_seq;

  v_app_no := 'APP-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

  insert into public.admission_application (
    tenant_id, campus_id, session_id, enquiry_id, application_no, class_applied_id, group_applied,
    submitted_by, prev_school, prev_class_passed
  ) values (
    app.auth_tenant_id(), v_enquiry.campus_id, v_enquiry.session_id, p_enquiry_id, v_app_no, v_enquiry.class_applied_id, v_group,
    auth.uid(), p_prev_school, p_prev_class_passed
  )
  returning id into v_app_id;

  update public.admission_enquiry set status = 'converted' where id = p_enquiry_id;

  return v_app_id;
end;
$$;

create or replace function public.fn_issue_offer(p_application_id uuid, p_admission_fee_amount numeric, p_valid_days int default 7)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app      public.admission_application%rowtype;
  v_available int;
  v_offer_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_app from public.admission_application where id = p_application_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_available := app.fn_available_seats(v_app.class_applied_id, v_app.session_id, v_app.campus_id);
  if v_available <= 0 then
    raise exception 'NO_SEATS_AVAILABLE'
      using errcode = '23514', detail = format('class_level_id=%s session_id=%s', v_app.class_applied_id, v_app.session_id);
  end if;

  insert into public.admission_offer (tenant_id, application_id, class_level_id, admission_fee_amount, issued_by, expires_at)
  values (
    app.auth_tenant_id(), p_application_id, v_app.class_applied_id, p_admission_fee_amount, auth.uid(),
    ((((now() at time zone 'Asia/Karachi')::date + p_valid_days) + time '23:59:59') at time zone 'Asia/Karachi')
  )
  returning id into v_offer_id;

  update public.admission_application set status = 'offered' where id = p_application_id;

  return v_offer_id;
end;
$$;

create or replace function public.fn_extend_offer(p_offer_id uuid, p_new_expires_at timestamptz, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.admission_offer
     set expires_at = p_new_expires_at, extended_by = auth.uid(), extension_reason = p_reason
   where id = p_offer_id and status = 'issued' and tenant_id = app.auth_tenant_id();

  if not found then
    raise exception 'OFFER_NOT_EXTENDABLE' using errcode = '55000';
  end if;
end;
$$;

create or replace function public.fn_respond_to_offer(
  p_offer_id uuid, p_response public.offer_status, p_decline_reason public.offer_decline_reason default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_app_id    uuid;
begin
  if p_response not in ('accepted', 'declined') then
    raise exception 'INVALID_RESPONSE' using errcode = '22023';
  end if;
  if p_response = 'declined' and p_decline_reason is null then
    raise exception 'DECLINE_REASON_REQUIRED' using errcode = '23514';
  end if;

  select tenant_id, application_id into v_tenant_id, v_app_id from public.admission_offer where id = p_offer_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.admission_offer
     set status = p_response, responded_at = now(), decline_reason = p_decline_reason
   where id = p_offer_id and status = 'issued';

  if not found then
    raise exception 'OFFER_NOT_RESPONDABLE' using errcode = '55000';
  end if;

  update public.admission_application
     set status = case p_response when 'accepted' then 'accepted'::public.application_status else 'declined'::public.application_status end
   where id = v_app_id;
end;
$$;

create or replace function public.fn_reinstate_offer(p_offer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer     public.admission_offer%rowtype;
  v_app       public.admission_application%rowtype;
  v_available int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_offer from public.admission_offer where id = p_offer_id;
  if not found or v_offer.tenant_id <> app.auth_tenant_id() or v_offer.status <> 'lapsed' then
    raise exception 'OFFER_NOT_LAPSED' using errcode = '55000';
  end if;
  select * into v_app from public.admission_application where id = v_offer.application_id;

  v_available := app.fn_available_seats(v_app.class_applied_id, v_app.session_id, v_app.campus_id);
  if v_available <= 0 then
    raise exception 'NO_SEATS_AVAILABLE' using errcode = '23514';
  end if;

  update public.admission_offer set status = 'issued', expires_at = now() + interval '7 days' where id = p_offer_id;
  update public.admission_application set status = 'offered' where id = v_offer.application_id;
end;
$$;

-- ── class_levels_and_enquiries.sql: create_enquiry ─────────────────────
-- p_session_id and p_class_applied_id were never tenant-checked at all
-- (only existence); p_campus_id was checked via campus_ids for non-owner
-- roles, but owner/super_admin skipped it entirely with nothing standing
-- in for the cross-tenant check that skip assumes is unnecessary.

create or replace function public.create_enquiry(
  p_campus_id           uuid,
  p_session_id          uuid,
  p_child_name          text,
  p_dob                 date,
  p_class_applied_id    uuid,
  p_parent_name         text,
  p_phone               text,
  p_whatsapp_opt_in     boolean,
  p_source              public.enquiry_source,
  p_child_name_ur       text default null,
  p_parent_cnic         text default null,
  p_referrer_name       text default null,
  p_age_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id             uuid;
  v_phone          text;
  v_class_ordinal  smallint;
  v_session_year   int;
  v_ref_date       date;
  v_age_months     int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_source = 'referral' and (p_referrer_name is null or btrim(p_referrer_name) = '') then
    raise exception 'Referrer required for referral enquiries' using errcode = '23514';
  end if;

  v_phone := public.normalize_pk_phone(p_phone);
  if v_phone is null then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;

  select ordinal into v_class_ordinal from public.class_level where id = p_class_applied_id and tenant_id = app.auth_tenant_id();
  if v_class_ordinal is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_class_ordinal = 0 then
    select starts_on into v_ref_date from public.academic_session where id = p_session_id;
    v_session_year := extract(year from v_ref_date);
    v_ref_date := make_date(v_session_year, 4, 1);
    v_age_months := extract(year from age(v_ref_date, p_dob))::int * 12 + extract(month from age(v_ref_date, p_dob))::int;
    if v_age_months < 30 and (p_age_override_reason is null or btrim(p_age_override_reason) = '') then
      raise exception 'AGE_BELOW_MINIMUM_NEEDS_OVERRIDE' using errcode = '23514';
    end if;
  end if;

  insert into public.admission_enquiry (
    tenant_id, campus_id, session_id, child_name, child_name_ur, dob, class_applied_id,
    parent_name, parent_cnic, phone_e164, whatsapp_opt_in, source, referrer_name,
    assigned_to, age_override_reason
  ) values (
    app.auth_tenant_id(), p_campus_id, p_session_id, p_child_name, p_child_name_ur, p_dob, p_class_applied_id,
    p_parent_name, p_parent_cnic, v_phone, p_whatsapp_opt_in, p_source, p_referrer_name,
    auth.uid(), p_age_override_reason
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- ── teacher_allocation.sql: assign_class_teacher, assign_subject_teacher ─

create or replace function public.assign_class_teacher(p_section_id uuid, p_staff_id uuid, p_effective_from date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section        public.class_section%rowtype;
  v_id             uuid;
  v_already_class_teacher boolean;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found or v_section.tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select exists (
    select 1 from public.section_class_teacher sct
     where sct.staff_id = p_staff_id and sct.session_id = v_section.session_id
       and sct.section_id <> p_section_id and sct.effective_to is null
  ) into v_already_class_teacher;

  update public.section_class_teacher
     set effective_to = p_effective_from - 1
   where section_id = p_section_id and effective_to is null and effective_from < p_effective_from;

  insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_staff_id, p_effective_from)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'warning', case when v_already_class_teacher then 'DUAL_CLASS_TEACHER' else null end);
end;
$$;

create or replace function public.assign_subject_teacher(
  p_section_id uuid, p_subject_id uuid, p_staff_id uuid, p_effective_from date, p_role public.allocation_role default 'primary'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found or v_section.tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_role = 'primary' then
    update public.section_subject_teacher
       set effective_to = p_effective_from - 1
     where section_id = p_section_id and subject_id = p_subject_id and role = 'primary'
       and effective_to is null and effective_from < p_effective_from;
  end if;

  insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, role, effective_from)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_section_id, p_subject_id, p_staff_id, p_role, p_effective_from)
  returning id into v_id;

  return v_id;
end;
$$;

-- ── enrolment.sql: enrol_student, create_section (current, widened body) ─

create or replace function public.enrol_student(p_section_id uuid, p_student_id uuid, p_override_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_section public.class_section%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_override_reason is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'OVERRIDE_REQUIRES_PRINCIPAL' using errcode = '42501';
  end if;

  select * into v_section from public.class_section where id = p_section_id;
  if not found or v_section.tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.student where id = p_student_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_section.gender_restriction is not null
     and (select gender from public.student where id = p_student_id) <> v_section.gender_restriction then
    raise exception 'SECTION_GENDER_RESTRICTED' using errcode = '23514';
  end if;

  insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, override_reason)
  values (app.auth_tenant_id(), v_section.campus_id, v_section.session_id, p_student_id, v_section.class_level_id, p_section_id, p_override_reason)
  returning id into v_id;

  insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
  values (v_id, p_section_id, current_date, auth.uid(), coalesce(p_override_reason, 'initial enrolment'));

  return v_id;
end;
$$;

create or replace function public.create_section(
  p_campus_id         uuid,
  p_session_id        uuid,
  p_class_level_id    uuid,
  p_name              text,
  p_capacity          int,
  p_medium            public.section_medium default 'ENGLISH',
  p_shift             public.section_shift default 'MORNING',
  p_gender_restriction public.gender default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_capacity < 1 or p_capacity > 200 then
    raise exception 'CAPACITY_OUT_OF_RANGE' using errcode = '23514';
  end if;

  if exists (
    select 1 from public.class_section
     where campus_id = p_campus_id and session_id = p_session_id
       and class_level_id = p_class_level_id and name = p_name
  ) then
    raise exception 'SECTION_NAME_DUPLICATE' using errcode = '23505';
  end if;

  insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, medium, shift, gender_restriction)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_name, p_capacity, p_medium, p_shift, p_gender_restriction)
  returning id into v_id;

  return v_id;
end;
$$;

-- ── roll_numbers.sql: fn_resequence_roll_numbers ───────────────────────
-- Had no tenant check at all — section_id + session_id alone were enough
-- to re-sequence any tenant's roll numbers.

create or replace function public.fn_resequence_roll_numbers(p_section_id uuid, p_session_id uuid, p_strategy text default 'alphabetical')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ids       uuid[];
  v_old_rolls int[];
  v_new_roll  int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_strategy <> 'alphabetical' then
    raise exception 'UNKNOWN_STRATEGY' using errcode = '22023';
  end if;
  if not exists (select 1 from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select array_agg(e.id order by s.name_en), array_agg(e.roll_no order by s.name_en)
    into v_ids, v_old_rolls
    from public.enrolment e
    join public.student s on s.id = e.student_id
   where e.section_id = p_section_id and e.session_id = p_session_id and e.status = 'active';

  update public.enrolment set roll_no = null
   where section_id = p_section_id and session_id = p_session_id and status = 'active';

  for i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    v_new_roll := i;
    if v_old_rolls[i] is distinct from v_new_roll then
      insert into public.roll_number_change_log (enrolment_id, old_roll_no, new_roll_no, strategy, changed_by)
      values (v_ids[i], v_old_rolls[i], v_new_roll, p_strategy, auth.uid());
    end if;
    update public.enrolment set roll_no = v_new_roll where id = v_ids[i];
  end loop;

  return v_new_roll;
end;
$$;

-- ── readmission_and_transport.sql: fn_readmit_student, fn_set_transport_optin ─

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
  if not found or v_student.tenant_id <> app.auth_tenant_id() then
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

  perform public.fn_change_student_status(
    p_student_id, 'active', 'readmission', current_date,
    case when v_student.no_readmission_flag then coalesce(p_override_reason, '') || ' [no_readmission override]' else p_override_reason end
  );

  v_enrolment_id := public.enrol_student(p_section_id, p_student_id);

  return v_enrolment_id;
end;
$$;

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
  if not found or v_student.tenant_id <> app.auth_tenant_id() then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select exists(
    select 1 from public.student_transport
     where student_id = p_student_id and session_id = p_session_id and to_date is null
  ) into v_had_open;

  v_month_end := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;

  if v_had_open then
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

-- ── class_subject_map.sql: upsert_class_subject ────────────────────────

create or replace function public.upsert_class_subject(
  p_campus_id       uuid,
  p_session_id      uuid,
  p_class_level_id  uuid,
  p_subject_id      uuid,
  p_weekly_periods  smallint,
  p_stream_id       uuid default null,
  p_is_compulsory   boolean default true,
  p_elective_bucket smallint default null,
  p_choose_n        smallint default null,
  p_max_marks       int default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_weekly_periods is null or p_weekly_periods < 1 then
    raise exception 'WEEKLY_PERIODS_REQUIRED' using errcode = '23514';
  end if;
  if not p_is_compulsory and p_elective_bucket is null then
    raise exception 'ELECTIVE_BUCKET_REQUIRED' using errcode = '23514';
  end if;

  insert into public.class_subject (
    tenant_id, campus_id, session_id, class_level_id, stream_id, subject_id,
    is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
  ) values (
    app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_stream_id, p_subject_id,
    p_is_compulsory, p_elective_bucket, p_choose_n, p_weekly_periods, p_max_marks
  )
  on conflict (session_id, campus_id, class_level_id, (coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)), subject_id)
  do update set
    is_compulsory   = excluded.is_compulsory,
    elective_bucket = excluded.elective_bucket,
    choose_n        = excluded.choose_n,
    weekly_periods  = excluded.weekly_periods,
    max_marks       = excluded.max_marks
  returning id into v_id;

  return v_id;
end;
$$;

-- ── staff_and_leave_types.sql: create_staff ─────────────────────────────
-- Had NO campus validation at all — not even existence — for any caller
-- role. p_campus_id fed straight into app.fn_next_employee_code(), which
-- could increment or read another tenant's actual employee-code counter.

create or replace function public.create_staff(
  p_campus_id        uuid,
  p_full_name        text,
  p_gender           public.gender,
  p_id_document_type public.id_document_type default 'cnic',
  p_cnic             text default null,
  p_passport_no      text default null,
  p_full_name_ur     text default null,
  p_contract_type    text default 'permanent',
  p_dob              date default null,
  p_doj              date default current_date,
  p_designation_id   uuid default null,
  p_department_id    uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_normalized_cnic  text;
  v_existing_code    text;
  v_employee_code    text;
  v_id               uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_id_document_type = 'cnic' then
    if p_cnic is null then
      raise exception 'CNIC_REQUIRED' using errcode = '23514';
    end if;
    v_normalized_cnic := app.fn_normalize_pk_id(p_cnic);

    select employee_code into v_existing_code
      from public.staff
     where tenant_id = app.auth_tenant_id() and cnic = v_normalized_cnic and employment_status = 'active'
     limit 1;
    if found then
      raise exception 'CNIC_CONFLICT' using errcode = '23505', detail = format('conflicting_employee_code=%s', v_existing_code);
    end if;
  elsif p_passport_no is null then
    raise exception 'PASSPORT_REQUIRED' using errcode = '23514';
  end if;

  v_employee_code := app.fn_next_employee_code(p_campus_id);

  insert into public.staff (
    tenant_id, campus_id, employee_code, id_document_type, cnic, passport_no, gender, contract_type,
    dob, doj, designation_id, department_id, full_name, full_name_ur
  ) values (
    app.auth_tenant_id(), p_campus_id, v_employee_code, p_id_document_type, v_normalized_cnic, p_passport_no, p_gender, p_contract_type,
    p_dob, p_doj, p_designation_id, p_department_id, p_full_name, p_full_name_ur
  )
  returning id into v_id;

  insert into public.staff_campus (staff_id, campus_id) values (v_id, p_campus_id);

  return v_id;
end;
$$;

-- ── leave_ledger_and_application.sql / leave_approval_chain.sql:
--    fn_decide_leave_application, apply_for_leave, advance_leave_approval ─

create or replace function public.fn_decide_leave_application(
  p_application_id uuid, p_decision public.leave_application_status, p_comment text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app public.leave_application%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INVALID_DECISION' using errcode = '22023';
  end if;

  select * into v_app from public.leave_application
   where id = p_application_id and status = 'pending' and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_PENDING' using errcode = '55000';
  end if;

  update public.leave_application
     set status = p_decision, decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
   where id = p_application_id;

  if p_decision = 'approved' then
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'consumption', -v_app.working_days, p_application_id, auth.uid());

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by)
    select v_app.tenant_id, v_app.campus_id, v_app.staff_id, d::date,
           case when v_app.is_half_day then 'half_day'::public.attendance_status else 'on_leave'::public.attendance_status end,
           'leave', auth.uid()
      from generate_series(v_app.from_date, v_app.to_date, interval '1 day') as d
    on conflict (staff_id, att_date) do update set status = excluded.status, source = 'leave';
  else
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
  end if;
end;
$$;

create or replace function public.apply_for_leave(
  p_staff_id      uuid,
  p_leave_type_id uuid,
  p_from_date     date,
  p_to_date       date,
  p_is_half_day   boolean default false,
  p_reason        text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_staff        public.staff%rowtype;
  v_working_days numeric;
  v_balance      numeric;
  v_app_id       uuid;
  v_step1        public.leave_approval_chain%rowtype;
  v_role         public.app_role;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager')
     and not exists (select 1 from public.staff where id = p_staff_id and user_id = auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_staff from public.staff where id = p_staff_id;
  if not found or v_staff.tenant_id <> app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_staff_id::text || p_leave_type_id::text, 0));

  if p_is_half_day then
    v_working_days := 0.5;
  else
    v_working_days := public.working_days_between(v_staff.campus_id, p_from_date, p_to_date);
  end if;

  v_balance := public.fn_leave_balance(p_staff_id, p_leave_type_id);
  if v_working_days > v_balance then
    raise exception 'INSUFFICIENT_BALANCE'
      using errcode = '23514', detail = format('available=%s requested=%s', v_balance, v_working_days);
  end if;

  insert into public.leave_application (
    tenant_id, campus_id, staff_id, leave_type_id, from_date, to_date, is_half_day, working_days, reason
  ) values (
    v_staff.tenant_id, v_staff.campus_id, p_staff_id, p_leave_type_id, p_from_date, p_to_date, p_is_half_day, v_working_days, p_reason
  )
  returning id into v_app_id;

  insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
  values (v_staff.tenant_id, p_staff_id, p_leave_type_id, 'hold', -v_working_days, v_app_id, auth.uid());

  select * into v_step1 from public.leave_approval_chain
   where campus_id = v_staff.campus_id and leave_type_id = p_leave_type_id and step_no = 1;
  if found then
    v_role := app.fn_resolve_leave_approver_role(p_staff_id, v_step1.approver_role);
    insert into public.leave_approval_step (application_id, step_no, effective_approver_role, sla_due_at)
    values (v_app_id, 1, v_role, now() + make_interval(hours => v_step1.sla_hours));
  end if;

  return v_app_id;
end;
$$;

create or replace function public.advance_leave_approval(p_application_id uuid, p_decision public.approval_decision, p_comment text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app            public.leave_application%rowtype;
  v_step           public.leave_approval_step%rowtype;
  v_next_chain_row public.leave_approval_chain%rowtype;
  v_next_role      public.app_role;
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INVALID_DECISION' using errcode = '22023';
  end if;

  select * into v_app from public.leave_application
   where id = p_application_id and status = 'pending' and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_PENDING' using errcode = '55000';
  end if;

  select * into v_step from public.leave_approval_step
   where application_id = p_application_id and decision in ('pending', 'escalated')
   order by step_no asc
   limit 1;
  if not found then
    raise exception 'NO_PENDING_STEP' using errcode = '55000';
  end if;

  if v_step.decision = 'escalated' then
    if app.auth_role() = v_step.effective_approver_role::text then
      raise exception 'STEP_ESCALATED' using errcode = '55000';
    end if;
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif app.auth_role() not in ('super_admin', 'owner') and app.auth_role() <> v_step.effective_approver_role::text then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.leave_approval_step
     set decision = p_decision, decided_at = now(), comment = p_comment, approver_id = auth.uid()
   where id = v_step.id;

  if p_decision = 'rejected' then
    update public.leave_application
       set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
     where id = p_application_id;

    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
    return;
  end if;

  select * into v_next_chain_row from public.leave_approval_chain
   where campus_id = v_app.campus_id and leave_type_id = v_app.leave_type_id and step_no = v_step.step_no + 1;

  if not found then
    update public.leave_application
       set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_comment = p_comment
     where id = p_application_id;

    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'hold_release', v_app.working_days, p_application_id, auth.uid());
    insert into public.leave_ledger (tenant_id, staff_id, leave_type_id, entry_type, days, reference_id, created_by)
    values (v_app.tenant_id, v_app.staff_id, v_app.leave_type_id, 'consumption', -v_app.working_days, p_application_id, auth.uid());

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by)
    select v_app.tenant_id, v_app.campus_id, v_app.staff_id, d::date,
           case when v_app.is_half_day then 'half_day'::public.attendance_status else 'on_leave'::public.attendance_status end,
           'leave', auth.uid()
      from generate_series(v_app.from_date, v_app.to_date, interval '1 day') as d
    on conflict (staff_id, att_date) do update set status = excluded.status, source = 'leave';
  else
    v_next_role := app.fn_resolve_leave_approver_role(v_app.staff_id, v_next_chain_row.approver_role);
    insert into public.leave_approval_step (application_id, step_no, effective_approver_role, sla_due_at)
    values (p_application_id, v_next_chain_row.step_no, v_next_role, now() + make_interval(hours => v_next_chain_row.sla_hours));
  end if;
end;
$$;
