-- Code review follow-up:
-- * A walk-in paid by bank or cheque printed the payer's reference as its receipt number. Every
--   paid walk-in now gets the campus's next receipt number, kept in receipt_no; the payer's
--   reference stays in reference_no.
-- * A school without an ADMISSION fee head got admission charges with no head, missing from
--   head-wise reports. Enrolment now adds the standard head when it is missing.

alter table public.admission_fee_payment add column if not exists receipt_no text;

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
  if v_enquiry.phone_e164 ~ '^\+92[0-9]{10}$' and nullif(btrim(v_enquiry.parent_name), '') is not null then
    select id into v_guardian_id from public.guardian
     where tenant_id = app.auth_tenant_id() and phone_e164 = v_enquiry.phone_e164
       and lower(btrim(name_en)) = lower(btrim(v_enquiry.parent_name))
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
     where tenant_id = app.auth_tenant_id() and lower(code) = 'admission' limit 1;
    if v_admission_head_id is null then
      insert into public.fee_head (tenant_id, code, name_en, name_ur, is_refundable, default_frequency, created_by)
      values (app.auth_tenant_id(), 'ADMISSION', 'Admission Fee', 'داخلہ فیس', false, 'one_time', auth.uid())
      returning id into v_admission_head_id;
    end if;
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

CREATE OR REPLACE FUNCTION public.fn_quick_admission(p_campus_id uuid, p_session_id uuid, p_child_name text, p_dob date, p_gender gender, p_class_level_id uuid, p_section_id uuid, p_parent_name text, p_phone text, p_admission_fee numeric DEFAULT 0, p_payment_mode text DEFAULT 'cash'::text, p_payment_reference text DEFAULT NULL::text, p_b_form_no text DEFAULT NULL::text, p_father_name_en text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_tenant_id        uuid := app.auth_tenant_id();
  v_receipt_no       text;
  v_enquiry_id       uuid;
  v_app_id           uuid;
  v_offer_id         uuid;
  v_payment_id       uuid;
  v_waiver_id        uuid;
  v_enrol_result     jsonb;
  v_ordinal          smallint;
  v_phone            text;
  v_fee_amount       numeric := coalesce(p_admission_fee, 0);
  v_fee_paisa        bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  perform app.fn_assert_campus_access(p_campus_id);

  if p_child_name is null or btrim(p_child_name) = '' then
    raise exception 'CHILD_NAME_REQUIRED' using errcode = '23514';
  end if;
  if p_dob is null then
    raise exception 'DOB_REQUIRED' using errcode = '23514';
  end if;
  if p_gender is null then
    raise exception 'GENDER_REQUIRED' using errcode = '23514';
  end if;
  if p_class_level_id is null then
    raise exception 'CLASS_REQUIRED' using errcode = '23514';
  end if;
  if p_section_id is null then
    raise exception 'SECTION_REQUIRED' using errcode = '23514';
  end if;

  -- Verify class level and section match
  select ordinal into v_ordinal from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CLASS_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.class_section where id = p_section_id and class_level_id = p_class_level_id and tenant_id = v_tenant_id) then
    raise exception 'SECTION_NOT_IN_CLASS' using errcode = '23514';
  end if;

  -- Phone normalization
  v_phone := public.normalize_pk_phone(p_phone);
  if v_phone is null then
    v_phone := coalesce(p_phone, '03000000000');
  end if;

  -- 1. Create Enquiry
  insert into public.admission_enquiry (
    tenant_id, campus_id, session_id, child_name, dob, class_applied_id,
    parent_name, phone_e164, whatsapp_opt_in, source, assigned_to, status
  ) values (
    v_tenant_id, p_campus_id, p_session_id, p_child_name, p_dob, p_class_level_id,
    p_parent_name, v_phone, false, 'walk_in', auth.uid(), 'open'
  )
  returning id into v_enquiry_id;

  -- 2. Convert to Application via official fn_submit_application
  v_app_id := public.fn_submit_application(v_enquiry_id);

  -- 3. Satisfy any mandatory checklist items as verified for walk-in
  insert into public.admission_document_submission (
    tenant_id, campus_id, application_id, doc_type, status, uploaded_count, updated_by, updated_at
  )
  select
    v_tenant_id,
    p_campus_id,
    v_app_id,
    (item ->> 'doc_type')::public.document_type,
    'verified'::public.doc_status,
    coalesce((item ->> 'min_count')::smallint, 1),
    auth.uid(),
    now()
  from jsonb_array_elements((select checklist_snapshot from public.admission_application where id = v_app_id)) item
  where (item ->> 'is_mandatory')::boolean = true
  on conflict (application_id, doc_type) do update
    set status = 'verified', uploaded_count = excluded.uploaded_count, updated_by = auth.uid(), updated_at = now();

  -- 4. Create Offer directly accepted
  insert into public.admission_offer (
    tenant_id, application_id, class_level_id, section_id, admission_fee_amount,
    issued_by, status, expires_at, responded_at
  ) values (
    v_tenant_id, v_app_id, p_class_level_id, p_section_id, v_fee_amount,
    auth.uid(), 'accepted', now() + interval '30 days', now()
  )
  returning id into v_offer_id;

  update public.admission_application set status = 'accepted' where id = v_app_id;

  -- 5. Payment or Waiver
  v_fee_paisa := round(v_fee_amount * 100)::bigint;

  -- Audit: the app used to invent a receipt number from the clock (REC-2026-857069). A receipt
  -- without a reference from the payer gets the campus's next gapless receipt number.
  if v_fee_amount > 0 then
    v_receipt_no := app.fn_next_receipt_no(v_tenant_id, p_campus_id, p_session_id);
    insert into public.admission_fee_payment (
      tenant_id, campus_id, offer_id, amount_paisa, mode, reference_no, receipt_no,
      recorded_by, status, reconciled_at, reconciled_by
    ) values (
      v_tenant_id, p_campus_id, v_offer_id, v_fee_paisa, p_payment_mode::public.fee_payment_mode,
      coalesce(nullif(btrim(p_payment_reference), ''), v_receipt_no), v_receipt_no,
      auth.uid(), 'reconciled', now(), auth.uid()
    )
    returning id into v_payment_id;
  else
    insert into public.admission_fee_waiver (
      tenant_id, campus_id, offer_id, reason, approved_by
    ) values (
      v_tenant_id, p_campus_id, v_offer_id, 'Walk-in direct admission zero fee waiver', auth.uid()
    )
    returning id into v_waiver_id;
  end if;

  -- 6. Enrol student using standard fn_enrol_from_offer
  v_enrol_result := public.fn_enrol_from_offer(
    v_offer_id,
    p_gender,
    p_payment_id => v_payment_id,
    p_waiver_id => v_waiver_id,
    p_father_name_en => p_father_name_en,
    p_b_form_no => p_b_form_no,
    p_section_id => p_section_id
  );

  return jsonb_build_object(
    'student_id', v_enrol_result ->> 'student_id',
    'enrolment_id', v_enrol_result ->> 'enrolment_id',
    'gr_number', v_enrol_result ->> 'gr_number',
    'receipt_no', case when v_fee_amount > 0 then v_receipt_no end,
    'application_id', v_app_id,
    'enquiry_id', v_enquiry_id,
    'offer_id', v_offer_id
  );
end;
$function$;
