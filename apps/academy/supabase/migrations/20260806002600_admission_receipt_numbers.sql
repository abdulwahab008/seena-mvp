-- Audit: walk-in admission receipts get a gapless campus receipt number. See the function body.
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
  v_receipt_no := coalesce(nullif(btrim(p_payment_reference), ''), app.fn_next_receipt_no(v_tenant_id, p_campus_id, p_session_id));

  if v_fee_amount > 0 then
    insert into public.admission_fee_payment (
      tenant_id, campus_id, offer_id, amount_paisa, mode, reference_no,
      recorded_by, status, reconciled_at, reconciled_by
    ) values (
      v_tenant_id, p_campus_id, v_offer_id, v_fee_paisa, p_payment_mode::public.fee_payment_mode, v_receipt_no,
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
