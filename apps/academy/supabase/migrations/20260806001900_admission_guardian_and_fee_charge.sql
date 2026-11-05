-- Audit BUG-10 and BUG-11: admitting a student (walk-in desk or the application pipeline, both
-- through fn_enrol_from_offer) now links the enquiry's parent as primary guardian and posts the
-- admission-fee charge alongside its payment. See the comments in the body.
CREATE OR REPLACE FUNCTION public.fn_enrol_from_offer(p_offer_id uuid, p_gender gender, p_payment_id uuid DEFAULT NULL::uuid, p_waiver_id uuid DEFAULT NULL::uuid, p_name_ur text DEFAULT NULL::text, p_father_name_en text DEFAULT NULL::text, p_father_name_ur text DEFAULT NULL::text, p_religion text DEFAULT NULL::text, p_nationality text DEFAULT 'PK'::text, p_b_form_no text DEFAULT NULL::text, p_blood_group text DEFAULT NULL::text, p_section_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_offer             public.admission_offer%rowtype;
  v_application       public.admission_application%rowtype;
  v_enquiry           public.admission_enquiry%rowtype;
  v_existing_enrolment public.enrolment%rowtype;
  v_payment           public.admission_fee_payment%rowtype;
  v_waiver            public.admission_fee_waiver%rowtype;
  v_section_id        uuid;
  v_guardian_id       uuid;
  v_admission_head_id uuid;
  v_reconciled_paisa  bigint;
  v_provisional_paisa bigint;
  v_required_paisa    bigint;
  v_gr                text;
  v_student_id        uuid;
  v_enrolment_id       uuid;
  v_normalized_bform  text;
  v_existing_bform    record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_gender is null then
    raise exception 'GENDER_REQUIRED' using errcode = '23514';
  end if;
  if (p_payment_id is null) = (p_waiver_id is null) then
    raise exception 'PAYMENT_OR_WAIVER_REQUIRED' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('enrol-from-offer:' || p_offer_id::text, 0));

  -- AC5: the same payment/waiver submitted twice is a no-op replay, not
  -- a second student.
  select * into v_existing_enrolment from public.enrolment where admission_offer_id = p_offer_id;
  if found then
    return jsonb_build_object(
      'student_id', v_existing_enrolment.student_id,
      'enrolment_id', v_existing_enrolment.id,
      'gr_number', (select gr_number from public.student where id = v_existing_enrolment.student_id),
      'is_replay', true
    );
  end if;

  select * into v_offer from public.admission_offer where id = p_offer_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_offer.status <> 'accepted' then
    raise exception 'OFFER_NOT_ACCEPTED' using errcode = '55000';
  end if;
  select * into v_application from public.admission_application where id = v_offer.application_id;
  perform app.fn_assert_campus_access(v_application.campus_id);
  select * into v_enquiry from public.admission_enquiry where id = v_application.enquiry_id;

  v_section_id := coalesce(v_offer.section_id, p_section_id);
  if v_section_id is null then
    raise exception 'SECTION_REQUIRED' using errcode = '23514';
  end if;

  v_required_paisa := round(v_offer.admission_fee_amount * 100)::bigint;

  if p_waiver_id is not null then
    select * into v_waiver from public.admission_fee_waiver
     where id = p_waiver_id and offer_id = p_offer_id and tenant_id = app.auth_tenant_id();
    if not found then
      raise exception 'WAIVER_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_waiver.consumed_by_enrolment_id is not null then
      raise exception 'WAIVER_ALREADY_CONSUMED' using errcode = '55000';
    end if;
  else
    select * into v_payment from public.admission_fee_payment
     where id = p_payment_id and offer_id = p_offer_id and tenant_id = app.auth_tenant_id();
    if not found then
      raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_payment.consumed_by_enrolment_id is not null then
      raise exception 'PAYMENT_ALREADY_CONSUMED' using errcode = '55000';
    end if;

    select coalesce(sum(amount_paisa) filter (where status = 'reconciled'), 0),
           coalesce(sum(amount_paisa) filter (where status = 'provisional'), 0)
      into v_reconciled_paisa, v_provisional_paisa
      from public.admission_fee_payment
     where offer_id = p_offer_id;

    if v_reconciled_paisa < v_required_paisa then
      if v_reconciled_paisa + v_provisional_paisa >= v_required_paisa then
        -- AC3: enough money exists, some of it just hasn't cleared the
        -- bank statement yet. The expiry clock was already paused back
        -- when record_admission_fee_payment() recorded that provisional
        -- payment (pausing here, in the same call as this raise, would
        -- be rolled back along with everything else this call did).
        raise exception 'PAYMENT_NOT_RECONCILED' using errcode = '55000';
      end if;
      raise exception using
        message = 'OUTSTANDING_BALANCE:' || to_char(round((v_required_paisa - v_reconciled_paisa - v_provisional_paisa) / 100.0)::bigint, 'FM999,999,999'),
        errcode = '55000';
    end if;
  end if;

  -- AC1/AC4 gate satisfied — allocate the GR number and create the
  -- student/enrolment/ledger rows atomically. Not calling
  -- create_student()/enrol_student() directly: create_student()'s role
  -- check excludes 'accountant', a caller this FR must allow.
  if p_b_form_no is not null and btrim(p_b_form_no) <> '' then
    v_normalized_bform := regexp_replace(p_b_form_no, '[^0-9]', '', 'g');
    if length(v_normalized_bform) <> 13 then
      raise exception 'BFORM_INVALID_FORMAT' using errcode = '23514';
    end if;
    v_normalized_bform := substr(v_normalized_bform, 1, 5) || '-' || substr(v_normalized_bform, 6, 7) || '-' || substr(v_normalized_bform, 13, 1);
    select id, gr_number into v_existing_bform from public.student
     where tenant_id = app.auth_tenant_id() and b_form_no = v_normalized_bform limit 1;
    if found then
      raise exception 'BFORM_DUPLICATE' using errcode = '23505',
        detail = format('existing_gr=%s existing_student_id=%s', v_existing_bform.gr_number, v_existing_bform.id);
    end if;
  end if;

  v_gr := app.fn_allocate_gr_number(v_application.campus_id);

  insert into public.student (
    tenant_id, campus_id, gr_number, name_en, name_ur, father_name_en, father_name_ur,
    dob, gender, religion, nationality, b_form_no, blood_group
  ) values (
    app.auth_tenant_id(), v_application.campus_id, v_gr, v_enquiry.child_name, coalesce(p_name_ur, v_enquiry.child_name_ur),
    p_father_name_en, p_father_name_ur, v_enquiry.dob, p_gender, p_religion, coalesce(p_nationality, 'PK'),
    v_normalized_bform, p_blood_group
  )
  returning id into v_student_id;

  insert into public.gr_ledger (campus_id, gr_number, student_id, allocated_by)
  values (v_application.campus_id, v_gr, v_student_id, auth.uid());

  -- Audit BUG-10: the parent's name and phone taken at the enquiry or walk-in desk became the
  -- student's primary guardian nowhere, so the profile said "No guardians linked yet". Link the
  -- existing guardian with that phone in this school, or create one.
  if v_enquiry.phone_e164 is not null and nullif(btrim(v_enquiry.parent_name), '') is not null then
    select id into v_guardian_id from public.guardian
     where tenant_id = app.auth_tenant_id() and phone_e164 = v_enquiry.phone_e164
     order by created_at limit 1;
    if v_guardian_id is null then
      insert into public.guardian (tenant_id, name_en, phone_e164, cnic)
      values (app.auth_tenant_id(), btrim(v_enquiry.parent_name), v_enquiry.phone_e164,
              case when v_enquiry.parent_cnic is not null and not exists (
                     select 1 from public.guardian g where g.tenant_id = app.auth_tenant_id() and g.cnic = v_enquiry.parent_cnic)
                   then v_enquiry.parent_cnic end)
      returning id into v_guardian_id;
    end if;
    insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing, receives_academic)
    values (app.auth_tenant_id(), v_student_id, v_guardian_id,
            case when p_father_name_en is not null and lower(btrim(p_father_name_en)) = lower(btrim(v_enquiry.parent_name))
                 then 'father' else 'other' end::public.guardian_relationship,
            true, true, true)
    on conflict do nothing;
  end if;

  insert into public.enrolment (
    tenant_id, campus_id, session_id, student_id, class_level_id, section_id,
    admission_offer_id, admission_fee_payment_id, admission_fee_waiver_id
  ) values (
    app.auth_tenant_id(), v_application.campus_id, v_application.session_id, v_student_id, v_offer.class_level_id, v_section_id,
    p_offer_id, p_payment_id, p_waiver_id
  )
  returning id into v_enrolment_id;

  insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
  values (v_enrolment_id, v_section_id, current_date, auth.uid(), 'admission enrolment');

  if p_payment_id is not null then
    update public.admission_fee_payment set consumed_by_enrolment_id = v_enrolment_id where id = p_payment_id;

    -- Raw insert, not post_ledger_entry(): that function's own role
    -- check ('super_admin','owner','accountant') would reject an
    -- admissions_officer, who this FR explicitly allows to run the gate.
    -- Audit BUG-11: the payment used to be posted with no matching charge, leaving every newly
    -- admitted student with a credit balance equal to the admission fee. Post the charge first.
    select id into v_admission_head_id from public.fee_head
     where tenant_id = app.auth_tenant_id() and code = 'ADMISSION' limit 1;
    insert into public.fee_ledger (
      tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
      value_date, source_type, source_id, reason, created_by
    ) values (
      app.auth_tenant_id(), v_application.campus_id, v_enrolment_id, v_application.session_id, 'charge', v_admission_head_id, v_required_paisa, 'debit',
      current_date, 'admission_offer', p_offer_id, 'Admission fee', auth.uid()
    );
    insert into public.fee_ledger (
      tenant_id, campus_id, enrolment_id, session_id, entry_type, amount_paisa, direction,
      value_date, source_type, source_id, created_by
    ) values (
      app.auth_tenant_id(), v_application.campus_id, v_enrolment_id, v_application.session_id, 'payment', v_required_paisa, 'credit',
      current_date, 'admission_fee_payment', p_payment_id, auth.uid()
    );
  else
    update public.admission_fee_waiver set consumed_by_enrolment_id = v_enrolment_id where id = p_waiver_id;
  end if;

  update public.admission_application set status = 'enrolled' where id = v_application.id;
  update public.admission_offer set expiry_paused_at = null, expiry_pause_reason = null where id = p_offer_id and expiry_paused_at is not null;

  return jsonb_build_object('student_id', v_student_id, 'enrolment_id', v_enrolment_id, 'gr_number', v_gr, 'is_replay', false);
end;
$function$;
