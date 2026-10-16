-- A guardian could never record a consent decision from the portal.
--
-- record_consent() stamped consent_record.recorded_by with the caller's own
-- auth.uid(). That column references public.app_user(user_id), and a guardian
-- has no app_user row by design: they are linked through guardian.auth_user_id
-- and carry app_role 'parent' in their token (custom_access_token_hook). So
-- every portal submission failed the foreign key (23503) and the family saw
-- only "Could not save your choice." The existing pgTAP test never caught it
-- because its setup gave the parent an app_user row the product never creates.
--
-- recorded_by means "the staff member who captured this on the family's
-- behalf" (see the paper and counter channels). When the guardian records their
-- own decision from the portal there is no staff member, and the guardian is
-- already identified by granted_by_guardian_id, so the column stays null.
-- Nothing else changes: same checks, same supersede logic, same return value.

create or replace function public.record_consent(
  p_student_id    uuid,
  p_purpose_code  text,
  p_guardian_id   uuid,
  p_decision      text,
  p_channel       text,
  p_evidence_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_student   public.student%rowtype;
  v_version   int;
  v_id        uuid := gen_random_uuid();
  v_is_parent boolean;
begin
  if v_tenant_id is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_decision not in ('granted', 'denied', 'withdrawn') then
    raise exception 'INVALID_DECISION' using errcode = '23514';
  end if;
  if p_channel not in ('portal', 'paper', 'counter', 'whatsapp') then
    raise exception 'INVALID_CHANNEL' using errcode = '23514';
  end if;
  if not exists (select 1 from public.consent_purpose where code = p_purpose_code) then
    raise exception 'CONSENT_PURPOSE_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_student from public.student where id = p_student_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_is_parent := v_role = 'parent';

  if v_is_parent then
    if not (p_student_id = any(app.auth_guardian_student_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if not exists (
      select 1 from public.guardian where id = p_guardian_id and tenant_id = v_tenant_id and auth_user_id = (select auth.uid())
    ) then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'a guardian may only record their own decision';
    end if;
    if p_channel <> 'portal' then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'a guardian may only record a portal consent';
    end if;
    if p_evidence_path is not null then
      raise exception 'FORBIDDEN' using errcode = '42501', detail = 'evidence is attached by staff';
    end if;
  else
    if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'receptionist') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if v_role not in ('super_admin', 'owner') and not (v_student.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  -- AC4's data precondition: a decision is only meaningful from someone
  -- the resolution will actually consider.
  if not exists (
    select 1 from public.student_guardian
     where student_id = p_student_id and guardian_id = p_guardian_id and to_date is null
  ) then
    raise exception 'GUARDIAN_NOT_LINKED' using errcode = 'P0002';
  end if;

  -- AC5: paper without a scan is refused before anything is written.
  if p_channel = 'paper' and p_evidence_path is null then
    raise exception 'EVIDENCE_REQUIRED' using errcode = '23514';
  end if;
  if p_evidence_path is not null
     and p_evidence_path not like (v_tenant_id::text || '/' || p_student_id::text || '/%') then
    raise exception 'EVIDENCE_PATH_MISMATCH' using errcode = '23514';
  end if;

  v_version := public.current_consent_text_version(v_tenant_id, p_purpose_code);

  -- Insert first, supersede second: superseded_by is a self-reference, so
  -- pointing the old rows at v_id before the row exists trips the FK.
  insert into public.consent_record (
    id, tenant_id, campus_id, student_id, purpose_code, decision,
    granted_by_guardian_id, channel, text_version, evidence_path, recorded_by
  ) values (
    v_id, v_tenant_id, v_student.campus_id, p_student_id, p_purpose_code, p_decision,
    p_guardian_id, p_channel, v_version, p_evidence_path,
    case when v_is_parent then null else (select auth.uid()) end
  );

  update public.consent_record
     set superseded_by = v_id
   where student_id = p_student_id
     and purpose_code = p_purpose_code
     and granted_by_guardian_id = p_guardian_id
     and superseded_by is null
     and id <> v_id;

  return jsonb_build_object(
    'consent_record_id', v_id,
    'text_version', v_version,
    'effective', public.has_consent(p_student_id, p_purpose_code)
  );
end;
$$;

