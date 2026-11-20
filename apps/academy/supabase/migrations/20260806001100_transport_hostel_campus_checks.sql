-- Campus checks for the transport and hostel functions that did not make them.
--
-- Found by reading every function the transport and hostel modules ship with a signed-in caller in
-- mind. Most of them load the record they act on and check that record's campus (the gate-pass
-- functions go through app.fn_hostel_assert_staff(), which checks the role and the campus of the
-- student, so an HR clerk, a nurse or a principal of another campus cannot issue, cancel or close a
-- pass). These did not:
--
--  * fn_set_transport_optin() changed the transport opt-in of any student of the school, whatever
--    campus the caller was assigned to.
--  * fn_readmit_student() re-activated any struck-off student of the school and enrolled them in any
--    section; fn_find_readmission_candidates() had no role check at all, so any signed-in user of the
--    school (a teacher, a nurse, a parent) could search every struck-off student by B-form number or
--    by name and date of birth.
--  * post_transport_charges() and post_hostel_charges() posted the month's fees for every campus of
--    the school, whichever campus the caller was assigned to.
--  * assert_vehicle_roadworthy() and assert_driver_eligible() answered for any vehicle and driver of
--    the school (document expiry, licence class and police verification) to any signed-in user.
--  * prorate_transport_fee() and transport_slab_amount() priced any allocation or fare slab of the
--    school for any signed-in user; billable_mess_days() and assert_bed_gender() answered for any
--    student (whether they board, their mess days, their gender against a bed) to any signed-in user.
--
-- Each now checks the role that uses it and the campus of the record, with the same helpers the rest of
-- the module uses. The monthly posting functions take an optional list of campuses; the scheduled
-- job still passes none and posts every campus.
--
-- Not changed, because they are school-wide configuration with no campus to check: set_transport_setting(),
-- set_hostel_setting() and create_gps_credential() (a device key for the whole school).


-- public.fn_set_transport_optin
create or replace function public.fn_set_transport_optin(p_student_id uuid, p_session_id uuid, p_opt_in boolean, p_direction transport_direction DEFAULT 'both'::transport_direction, p_pickup_area text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if app.auth_role() not in ('super_admin', 'owner') and not (v_student.campus_id = any (app.auth_campus_ids())) then
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
$function$;

-- public.fn_readmit_student
create or replace function public.fn_readmit_student(p_student_id uuid, p_section_id uuid, p_override_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if app.auth_role() not in ('super_admin', 'owner') and not (v_student.campus_id = any (app.auth_campus_ids())) then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.class_section sec
     where sec.id = p_section_id and sec.tenant_id = app.auth_tenant_id()
       and (app.auth_role() in ('super_admin', 'owner') or sec.campus_id = any (app.auth_campus_ids()))
  ) then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
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
$function$;

-- public.fn_find_readmission_candidates
-- Same roles as fn_readmit_student(), and only the struck-off students of the caller's own campuses.
create or replace function public.fn_find_readmission_candidates(p_b_form_no text default null::text, p_name_en text default null::text, p_dob date default null::date)
 returns table(student_id uuid, gr_number text, name_en text, status public.student_status, no_readmission_flag boolean)
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
  select s.id, s.gr_number, s.name_en, s.status, s.no_readmission_flag
    from public.student s
   where s.tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any (app.auth_campus_ids()))
     and s.status <> 'active'
     and (
       (p_b_form_no is not null and s.b_form_no = app.fn_normalize_pk_id(p_b_form_no))
       or (p_name_en is not null and p_dob is not null and lower(s.name_en) = lower(p_name_en) and s.dob = p_dob)
     );
end;
$function$;

-- The monthly posting functions take an optional list of campuses (null = every campus, which is what the
-- scheduled job wants). The two-argument forms are replaced, not overloaded, so a call with two arguments
-- keeps working.
drop function if exists app.fn_post_transport_month(uuid, date);
create or replace function app.fn_post_transport_month(p_tenant uuid, p_month date, p_campus_ids uuid[] default null)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_ms date := date_trunc('month', p_month)::date;
  v_me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  r    record;
  v_n  int := 0;
begin
  for r in
    select a.id from public.transport_allocation a
     where (p_tenant is null or a.tenant_id = p_tenant) and a.starts_on <= v_me and coalesce(a.ends_on, v_me) >= v_ms
       and (p_campus_ids is null or a.campus_id = any (p_campus_ids))
     order by a.starts_on, a.created_at
  loop
    v_n := v_n + app.fn_transport_post_allocation(r.id, v_ms);
  end loop;
  return v_n;
end;
$function$;
revoke all on function app.fn_post_transport_month(uuid, date, uuid[]) from public, anon, authenticated;

create or replace function public.post_transport_charges(p_month date)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal', 'transport_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- Owner and super admin post every campus; everyone else only the campuses they are assigned to.
  return app.fn_post_transport_month(
    app.auth_tenant_id(), p_month,
    case when app.auth_role() in ('owner', 'super_admin') then null else app.auth_campus_ids() end
  );
end;
$function$;
drop function if exists app.fn_post_hostel_month(uuid, date);
create or replace function app.fn_post_hostel_month(p_tenant uuid, p_month date, p_campus_ids uuid[] default null)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
declare
  v_ms date := date_trunc('month', p_month)::date;
  v_me date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  r    record;
  v_n  int := 0;
begin
  for r in
    select distinct a.student_id from public.hostel_allocation a
     where (p_tenant is null or a.tenant_id = p_tenant) and a.starts_on <= v_me and coalesce(a.ends_on, v_me) >= v_ms
       and (p_campus_ids is null or a.campus_id = any (p_campus_ids))
  loop
    v_n := v_n + app.fn_hostel_post_student(r.student_id, v_ms);
  end loop;
  return v_n;
end;
$function$;
revoke all on function app.fn_post_hostel_month(uuid, date, uuid[]) from public, anon, authenticated;

create or replace function public.post_hostel_charges(p_month date)
 returns integer
 language plpgsql
 security definer
 set search_path to ''
as $function$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_post_hostel_month(
    app.auth_tenant_id(), p_month,
    case when app.auth_role() in ('owner', 'super_admin') then null else app.auth_campus_ids() end
  );
end;
$function$;

-- public.assert_vehicle_roadworthy: the transport managers of the vehicle's own campus
create or replace function public.assert_vehicle_roadworthy(p_vehicle_id uuid, p_on date)
 returns void
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare
  v_campus uuid;
begin
  select v.campus_id into v_campus from public.transport_vehicle v where v.id = p_vehicle_id and v.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_campus);
  perform app.fn_vehicle_assert(p_vehicle_id, p_on);
end;
$function$;

-- public.assert_driver_eligible: the transport managers of the driver's and the vehicle's campus
create or replace function public.assert_driver_eligible(p_crew_id uuid, p_vehicle_id uuid, p_on date)
 returns text
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare
  v_crew_campus    uuid;
  v_vehicle_campus uuid;
begin
  select c.campus_id into v_crew_campus from public.transport_crew c where c.id = p_crew_id and c.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CREW_NOT_FOUND' using errcode = 'P0002';
  end if;
  select v.campus_id into v_vehicle_campus from public.transport_vehicle v where v.id = p_vehicle_id and v.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CREW_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_crew_campus);
  perform app.fn_transport_assert_manager(v_vehicle_campus);
  return app.fn_driver_assert(p_crew_id, p_vehicle_id, p_on);
end;
$function$;

-- public.prorate_transport_fee / transport_slab_amount: the roles that allocate transport, and only for the
-- caller's own campuses
create or replace function public.prorate_transport_fee(p_allocation_id uuid, p_month date)
 returns bigint
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare
  v_a public.transport_allocation%rowtype;
begin
  perform app.fn_transport_allocator_check();
  select * into v_a from public.transport_allocation where id = p_allocation_id and tenant_id = app.auth_tenant_id();
  if not found or (app.auth_role() not in ('owner', 'super_admin') and not (v_a.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'ALLOCATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_prorate_transport(v_a, p_month);
end;
$function$;

create or replace function public.transport_slab_amount(p_slab_id uuid, p_on date)
 returns bigint
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  perform app.fn_transport_allocator_check();
  return (select app.fn_slab_amount(s.id, p_on)
            from public.transport_fare_slab s
           where s.id = p_slab_id and app.fn_campus_scope(s.tenant_id, s.campus_id));
end;
$function$;

-- public.assert_bed_gender: the hostel staff of the student's campus
create or replace function public.assert_bed_gender(p_student_id uuid, p_bed_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_sg public.gender;
  v_bg public.hostel_gender;
  v_campus uuid;
begin
  select s.gender, s.campus_id into v_sg, v_campus from public.student s where s.id = p_student_id and s.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_hostel_assert_staff(v_campus);
  select b.gender into v_bg
    from public.hostel_bed d join public.hostel_room r on r.id = d.room_id join public.hostel_block b on b.id = r.block_id
   where d.id = p_bed_id and d.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'BED_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_sg::text is distinct from v_bg::text then
    raise exception 'GENDER_MISMATCH' using errcode = '23514';
  end if;
end;
$function$;

-- public.billable_mess_days: the student's own family, the hostel staff and the fee staff of the student's campus
create or replace function public.billable_mess_days(p_student_id uuid, p_month date)
 returns integer
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
declare
  v_stud public.student%rowtype;
begin
  select * into v_stud from public.student s where s.id = p_student_id and s.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  -- my_student_id() is NULL for anyone but a student, which makes the comparison NULL: that must count as "no"
  if not coalesce(
    v_stud.id = any (app.auth_guardian_student_ids())
    or v_stud.id = public.my_student_id()
    or app.fn_hostel_staff(v_stud.tenant_id, v_stud.campus_id)
    or app.fn_hostel_fee_staff(v_stud.tenant_id, v_stud.campus_id),
    false
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_billable_mess_days(p_student_id, p_month);
end;
$function$;
