-- The money functions check the caller's campus, not only their role.
--
-- A campus-scoped Accountant, Principal or Admissions Officer is fenced to their own campuses
-- by row-level security (FR-A12), but the record-level functions below are SECURITY DEFINER and
-- only checked the role and the tenant. Any accountant could therefore post a payment or ledger
-- entry against, read the challan, receipt or balance of, award or approve a concession for, or
-- move a deposit of a student at another campus of the same school just by passing that
-- record's id.
--
-- app.fn_assert_campus_access(campus_id) is now the one place that rule lives: an Owner or
-- Super Admin reaches every campus of their tenant, everyone else needs the campus in their
-- token. Each function calls it as soon as it has loaded the record it acts on.
-- app.fn_can_view_enrolment() is the read-side equivalent for outstanding_balance_as_of() and
-- student_balance(), which had no authorisation at all beyond the tenant and so also told a
-- parent the balance of somebody else's child.
--
-- Also closed on the way:
--  * apply_advance_credit() had no role check and never required the challan to belong to the
--    enrolment, so it could move one student's unallocated payments onto another's challan.
--  * build_fee_plan() had no role check.
--  * lookup_challan_for_counter() is limited to the caller's campuses in its WHERE clause,
--    because challan numbers are issued per campus and so repeat across campuses.
--  * The gateway webhook posts payments through app.fn_post_system_payment(), which acts as an
--    accountant of the payer's tenant; it now carries the payer's campus as well, so the check
--    passes for it exactly as it does for a cashier at that campus.
--
-- Left alone on purpose: functions restricted to Owner and Super Admin (they reach every
-- campus), tenant-wide setup (fee heads, schemes, structures, gateway import files) and the
-- staff-settlement functions, which already check the campus through
-- app.fn_settlement_actor_ok().

create or replace function app.fn_assert_campus_access(p_campus_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.campus c where c.id = p_campus_id and c.tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() in ('super_admin', 'owner') or p_campus_id = any (app.auth_campus_ids()) then
    return;
  end if;
  raise exception 'FORBIDDEN' using errcode = '42501', detail = 'that record belongs to a campus you are not assigned to';
end;
$$;

create or replace function app.fn_can_view_enrolment(p_enrolment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.enrolment e
     where e.id = p_enrolment_id and e.tenant_id = app.auth_tenant_id()
       and (
         (app.auth_role() = 'parent' and e.student_id = any (app.auth_guardian_student_ids()))
         or (app.auth_role() = 'student' and e.student_id = public.my_student_id())
         or (app.auth_role() not in ('parent', 'student', 'none')
             and (app.auth_role() in ('owner', 'super_admin') or e.campus_id = any (app.auth_campus_ids())))
       )
  );
$$;

revoke all on function app.fn_assert_campus_access(uuid) from public, anon, authenticated;
revoke all on function app.fn_can_view_enrolment(uuid) from public, anon, authenticated;

-- public.record_payment
create or replace function public.record_payment(p_enrolment_id uuid, p_amount_paisa bigint, p_mode public.fee_payment_mode, p_reference_no text default null::text, p_value_date date default current_date)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_enrolment public.enrolment%rowtype;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_enrolment.campus_id);

  insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode, value_date, reference_no, collected_by)
  values (v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_amount_paisa, p_mode, p_value_date, p_reference_no, auth.uid())
  returning id into v_id;

  perform public.post_ledger_entry(p_enrolment_id, 'payment', p_amount_paisa, 'credit', null, p_value_date, 'fee_payment', v_id);
  perform public.allocate_payment(v_id);

  return v_id;
end;
$function$;

-- public.post_ledger_entry
create or replace function public.post_ledger_entry(p_enrolment_id uuid, p_entry_type public.fee_ledger_entry_type, p_amount_paisa bigint, p_direction public.fee_ledger_direction, p_fee_head_id uuid default null::uuid, p_value_date date default current_date, p_source_type text default null::text, p_source_id uuid default null::uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_enrolment public.enrolment%rowtype;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_enrolment.campus_id);

  insert into public.fee_ledger (
    tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
    value_date, source_type, source_id, created_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, v_enrolment.session_id, p_entry_type, p_fee_head_id, p_amount_paisa, p_direction,
    p_value_date, p_source_type, p_source_id, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$function$;

-- public.allocate_payment
create or replace function public.allocate_payment(p_payment_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_payment         public.fee_payment%rowtype;
  v_available       bigint;
  v_challan         record;
  v_this_alloc      bigint;
  v_total_allocated bigint := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_payment from public.fee_payment where id = p_payment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'PAYMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_payment.campus_id);

  perform pg_advisory_xact_lock(hashtextextended('payment-alloc:' || v_payment.enrolment_id::text, 0));

  select v_payment.amount_paisa - coalesce(sum(amount_paisa), 0) into v_available
    from public.fee_payment_allocation where payment_id = p_payment_id;

  for v_challan in
    select id from public.fee_challan
     where enrolment_id = v_payment.enrolment_id and status in ('unpaid', 'part_paid')
     order by billing_period asc
  loop
    exit when v_available <= 0;
    v_this_alloc := app.fn_allocate_to_challan(p_payment_id, v_challan.id, v_available);
    v_available := v_available - v_this_alloc;
    v_total_allocated := v_total_allocated + v_this_alloc;
  end loop;

  return jsonb_build_object('payment_id', p_payment_id, 'allocated', v_total_allocated, 'unallocated', v_available);
end;
$function$;

-- public.apply_advance_credit
create or replace function public.apply_advance_credit(p_enrolment_id uuid, p_challan_id uuid)
 returns bigint
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id      uuid;
  v_challan_tenant uuid;
  v_net_paisa      bigint;
  v_credit_pay     record;
  v_this_alloc     bigint;
  v_total_applied  bigint := 0;
  v_remaining_need bigint;
  v_campus_id      uuid;
  v_challan_enrol  uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, campus_id into v_tenant_id, v_campus_id from public.enrolment where id = p_enrolment_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  select tenant_id, enrolment_id into v_challan_tenant, v_challan_enrol from public.fee_challan where id = p_challan_id;
  if v_challan_tenant is null or v_challan_tenant <> app.auth_tenant_id() or v_challan_enrol <> p_enrolment_id then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_campus_id);
  select coalesce(sum(net_paisa), 0) into v_net_paisa
    from public.fee_challan_line where challan_id = p_challan_id and line_type in ('charge', 'late_fee');

  perform pg_advisory_xact_lock(hashtextextended('payment-alloc:' || p_enrolment_id::text, 0));

  for v_credit_pay in
    select fp.id, fp.amount_paisa - coalesce(sum(fpa.amount_paisa), 0) as unallocated
      from public.fee_payment fp
      left join public.fee_payment_allocation fpa on fpa.payment_id = fp.id
     where fp.enrolment_id = p_enrolment_id
     group by fp.id, fp.amount_paisa, fp.received_at
    having fp.amount_paisa - coalesce(sum(fpa.amount_paisa), 0) > 0
     order by fp.received_at asc
  loop
    select coalesce(sum(amount_paisa), 0) into v_remaining_need from public.fee_payment_allocation where challan_id = p_challan_id;
    v_remaining_need := v_net_paisa - v_remaining_need;
    exit when v_remaining_need <= 0;

    v_this_alloc := app.fn_allocate_to_challan(v_credit_pay.id, p_challan_id, least(v_credit_pay.unallocated, v_remaining_need)::bigint);
    v_total_applied := v_total_applied + v_this_alloc;
  end loop;

  return v_total_applied;
end;
$function$;

-- public.compute_late_fee
create or replace function public.compute_late_fee(p_challan_id uuid, p_as_of date default current_date)
 returns bigint
 language plpgsql
 stable security definer
 set search_path = ''
as $function$
declare
  v_challan public.fee_challan%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_challan.campus_id);

  return app.fn_compute_late_fee(v_challan, p_as_of);
end;
$function$;

-- public.lookup_challan_for_counter
create or replace function public.lookup_challan_for_counter(p_challan_no text)
 returns jsonb
 language plpgsql
 stable security definer
 set search_path = ''
as $function$
declare
  v_challan  public.fee_challan%rowtype;
  v_student  record;
  v_allocated bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan
   where challan_no = p_challan_no and tenant_id = app.auth_tenant_id()
     and (app.auth_role() in ('super_admin', 'owner') or campus_id = any (app.auth_campus_ids()));
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select s.name_en, s.gr_number into v_student
    from public.enrolment e join public.student s on s.id = e.student_id
   where e.id = v_challan.enrolment_id;

  select coalesce(sum(amount_paisa), 0) into v_allocated from public.fee_payment_allocation where challan_id = v_challan.id;

  return jsonb_build_object(
    'challan_id', v_challan.id,
    'enrolment_id', v_challan.enrolment_id,
    'student_name', v_student.name_en,
    'gr_number', v_student.gr_number,
    'net_paisa', v_challan.net_paisa,
    'outstanding_paisa', greatest(v_challan.net_paisa - v_allocated, 0),
    'status', v_challan.status
  );
end;
$function$;

-- public.build_challan_render_payload
create or replace function public.build_challan_render_payload(p_challan_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus_id from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_campus_id);
  return app.fn_challan_payload(p_challan_id);
end;
$function$;

-- public.outstanding_balance_as_of
create or replace function public.outstanding_balance_as_of(p_enrolment_id uuid, p_as_of timestamp with time zone default now())
 returns bigint
 language sql
 stable security definer
 set search_path = ''
as $function$
  select coalesce(sum(case when l.direction = 'debit' then l.amount_paisa else -l.amount_paisa end), 0)::bigint
    from public.fee_ledger l
   where l.enrolment_id = p_enrolment_id
     and l.tenant_id = app.auth_tenant_id()
     and app.fn_can_view_enrolment(p_enrolment_id)
     and l.posted_at <= p_as_of
     and not exists (
       select 1 from public.fee_challan c
        where c.id = coalesce(l.challan_id, case when l.source_type = 'fee_challan' then l.source_id end)
          and c.deleted_at is not null
     );
$function$;

-- public.print_receipt
create or replace function public.print_receipt(p_receipt_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_receipt  public.fee_receipt%rowtype;
  v_payment  public.fee_payment%rowtype;
  v_student  record;
  v_balance  bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_receipt from public.fee_receipt where id = p_receipt_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'RECEIPT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_receipt.campus_id);

  update public.fee_receipt set printed_count = printed_count + 1 where id = p_receipt_id
  returning * into v_receipt;

  insert into public.fee_receipt_print_log (receipt_id, printed_by) values (p_receipt_id, auth.uid());

  select * into v_payment from public.fee_payment where id = v_receipt.payment_id;
  select s.name_en, s.gr_number into v_student
    from public.enrolment e join public.student s on s.id = e.student_id
   where e.id = v_payment.enrolment_id;
  v_balance := public.student_balance(v_payment.enrolment_id);

  return jsonb_build_object(
    'receipt_no', v_receipt.receipt_no,
    'student_name', v_student.name_en,
    'gr_number', v_student.gr_number,
    'amount_paisa', v_payment.amount_paisa,
    'amount_words', public.amount_in_words(v_payment.amount_paisa),
    'value_date', v_payment.value_date,
    'post_payment_outstanding_paisa', greatest(v_balance, 0),
    'printed_count', v_receipt.printed_count,
    'is_duplicate', v_receipt.printed_count > 1
  );
end;
$function$;

-- public.collect_cash_payment
create or replace function public.collect_cash_payment(p_challan_id uuid, p_amount_paisa bigint, p_client_idempotency_key text, p_mode public.fee_payment_mode default 'cash'::public.fee_payment_mode, p_reference_no text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_challan    public.fee_challan%rowtype;
  v_existing   record;
  v_payment_id uuid;
  v_receipt_id uuid;
  v_receipt_no text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_client_idempotency_key is null or btrim(p_client_idempotency_key) = '' then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED' using errcode = '23514';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('collect-cash:' || v_tenant_id::text || ':' || p_client_idempotency_key, 0));

  -- A retry (flaky connection, double-tapped Confirm) replays the
  -- original outcome untouched — no second payment, no second ledger
  -- credit, no second receipt number burned.
  select fr.id as receipt_id, fr.receipt_no, fr.payment_id
    into v_existing
    from public.fee_receipt fr
   where fr.tenant_id = v_tenant_id and fr.client_idempotency_key = p_client_idempotency_key;
  if found then
    return jsonb_build_object(
      'receipt_id', v_existing.receipt_id, 'receipt_no', v_existing.receipt_no,
      'payment_id', v_existing.payment_id, 'is_replay', true
    );
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_challan.campus_id);

  v_payment_id := public.record_payment(v_challan.enrolment_id, p_amount_paisa, p_mode, p_reference_no);
  v_receipt_no := app.fn_next_receipt_no(v_tenant_id, v_challan.campus_id, v_challan.session_id);

  insert into public.fee_receipt (tenant_id, campus_id, payment_id, receipt_no, client_idempotency_key)
  values (v_tenant_id, v_challan.campus_id, v_payment_id, v_receipt_no, p_client_idempotency_key)
  returning id into v_receipt_id;

  return jsonb_build_object(
    'receipt_id', v_receipt_id, 'receipt_no', v_receipt_no, 'payment_id', v_payment_id, 'is_replay', false
  );
end;
$function$;

-- public.request_concession_award
create or replace function public.request_concession_award(p_enrolment_id uuid, p_scheme_id uuid, p_value numeric, p_effective_from date, p_effective_to date, p_document_paths text[] default '{}'::text[])
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_enrolment public.enrolment%rowtype;
  v_scheme    public.concession_scheme%rowtype;
  v_award_id  uuid;
  v_path      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_value < 0 then
    raise exception 'VALUE_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_enrolment.campus_id);

  select * into v_scheme from public.concession_scheme where id = p_scheme_id and tenant_id = app.auth_tenant_id() and is_active;
  if not found then
    raise exception 'CONCESSION_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_scheme.calc_type = 'percentage' and p_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  if v_scheme.requires_document and coalesce(array_length(p_document_paths, 1), 0) = 0 then
    raise exception 'DOCUMENT_REQUIRED' using errcode = '23514';
  end if;

  if p_effective_to <= p_effective_from then
    raise exception 'EFFECTIVE_TO_MUST_FOLLOW_FROM' using errcode = '23514';
  end if;

  insert into public.concession_award (
    tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, requested_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_scheme_id, v_scheme.calc_type, p_value, p_effective_from, p_effective_to, auth.uid()
  )
  returning id into v_award_id;

  foreach v_path in array p_document_paths loop
    insert into public.concession_award_document (award_id, storage_path, uploaded_by) values (v_award_id, v_path, auth.uid());
  end loop;

  return v_award_id;
end;
$function$;

-- public.decide_concession_award
create or replace function public.decide_concession_award(p_award_id uuid, p_approve boolean, p_rejection_reason text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_award  public.concession_award%rowtype;
  v_scheme public.concession_scheme%rowtype;
begin
  select * into v_award from public.concession_award where id = p_award_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CONCESSION_AWARD_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_award.campus_id);

  if v_award.status <> 'pending' then
    raise exception 'AWARD_NOT_PENDING' using errcode = '55000';
  end if;

  select * into v_scheme from public.concession_scheme where id = v_award.scheme_id;
  if app.auth_role() not in ('super_admin', 'owner') and app.auth_role() <> v_scheme.approver_role::text then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_approve then
    update public.concession_award
       set status = 'approved', approved_by = auth.uid(), approved_at = now(), rejection_reason = null
     where id = p_award_id;
  else
    if p_rejection_reason is null or length(btrim(p_rejection_reason)) < 10 then
      raise exception 'REJECTION_REASON_TOO_SHORT' using errcode = '23514';
    end if;
    update public.concession_award
       set status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_rejection_reason
     where id = p_award_id;
  end if;
end;
$function$;

-- public.edit_concession_award
create or replace function public.edit_concession_award(p_award_id uuid, p_new_value numeric)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_award  public.concession_award%rowtype;
  v_scheme public.concession_scheme%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_new_value < 0 then
    raise exception 'VALUE_MUST_BE_NONNEGATIVE' using errcode = '23514';
  end if;

  select * into v_award from public.concession_award where id = p_award_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CONCESSION_AWARD_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform app.fn_assert_campus_access(v_award.campus_id);

  select * into v_scheme from public.concession_scheme where id = v_award.scheme_id;
  if v_award.calc_type = 'percentage' and p_new_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_new_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  update public.concession_award set value = p_new_value where id = p_award_id;
end;
$function$;

-- public.create_payment_intent
create or replace function public.create_payment_intent(p_challan_id uuid, p_gateway text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_challan   record;
  v_intent    public.payment_intent%rowtype;
  v_balance   bigint;
  v_ref       text;
begin
  if app.auth_role() not in ('parent', 'accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select c.id, c.campus_id, c.enrolment_id, c.challan_no, c.status, e.student_id
    into v_challan
    from public.fee_challan c
    join public.enrolment e on e.id = c.enrolment_id
   where c.id = p_challan_id and c.tenant_id = v_tenant_id and c.deleted_at is null;
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_role() <> 'parent' then
    perform app.fn_assert_campus_access(v_challan.campus_id);
  end if;

  if app.auth_role() = 'parent' and not exists (
    select 1 from public.student_guardian sg
      join public.guardian g on g.id = sg.guardian_id
     where g.auth_user_id = (select auth.uid()) and sg.student_id = v_challan.student_id
       and sg.to_date is null and sg.portal_access and sg.receives_billing
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_challan.status in ('paid', 'cancelled') then
    raise exception 'CHALLAN_ALREADY_SETTLED' using errcode = '55000';
  end if;
  v_balance := app.fn_challan_balance(p_challan_id);
  if v_balance is null or v_balance <= 0 then
    raise exception 'CHALLAN_ALREADY_SETTLED' using errcode = '55000';
  end if;

  if not exists (select 1 from public.payment_gateway_config where tenant_id = v_tenant_id and gateway = p_gateway and is_enabled) then
    raise exception 'GATEWAY_NOT_CONFIGURED' using errcode = '22023';
  end if;

  -- Idempotent: an unexpired live intent for this challan+gateway is returned as-is.
  update public.payment_intent set status = 'expired', updated_at = now()
   where challan_id = p_challan_id and gateway = p_gateway and status in ('initiated', 'pending') and expires_at <= now();

  select * into v_intent from public.payment_intent
   where challan_id = p_challan_id and gateway = p_gateway and status in ('initiated', 'pending');

  if not found then
    -- 1LINK vouchers must carry the challan number so the settlement file matches.
    v_ref := case when p_gateway = 'onelink' then v_challan.challan_no
                  else upper(left(p_gateway, 2)) || '-' || encode(extensions.gen_random_bytes(9), 'hex') end;
    insert into public.payment_intent (tenant_id, campus_id, enrolment_id, challan_id, gateway, gateway_ref, amount_paisa, expires_at, created_by)
    values (v_tenant_id, v_challan.campus_id, v_challan.enrolment_id, p_challan_id, p_gateway, v_ref, v_balance, now() + interval '30 minutes', (select auth.uid()))
    returning * into v_intent;
  end if;

  return jsonb_build_object(
    'intent_id', v_intent.id, 'gateway', v_intent.gateway, 'gateway_ref', v_intent.gateway_ref,
    'amount_paisa', v_intent.amount_paisa, 'expires_at', v_intent.expires_at
  );
end;
$function$;

-- public.disburse_fee_settlement
create or replace function public.disburse_fee_settlement(p_settlement_id uuid, p_instrument_type text, p_instrument_ref text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_s       public.fee_settlement%rowtype;
  v_calc    jsonb;
  v_balance bigint;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_s from public.fee_settlement where id = p_settlement_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'SETTLEMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_s.campus_id);

  if v_s.status <> 'approved' then
    raise exception 'SETTLEMENT_NOT_APPROVED' using errcode = '55000';
  end if;
  if p_instrument_type not in ('cash', 'cheque', 'transfer') or (p_instrument_type <> 'cash' and length(btrim(coalesce(p_instrument_ref, ''))) = 0) then
    raise exception 'INSTRUMENT_REFERENCE_REQUIRED' using errcode = '22023';
  end if;

  -- nothing may have moved since the proposal: a payment or a new charge would make the numbers wrong
  v_calc := public.compute_withdrawal_settlement(v_s.enrolment_id, v_s.leaving_date, v_s.basis);
  if (v_calc ->> 'ledger_balance_paisa')::bigint <> v_s.ledger_balance_paisa or (v_calc ->> 'credit_adjustment_paisa')::bigint <> v_s.credit_adjustment_paisa then
    raise exception 'LEDGER_MOVED_SINCE_PROPOSAL' using errcode = '55000', hint = 'Withdraw this proposal and propose again';
  end if;

  if v_s.credit_adjustment_paisa > 0 then
    perform public.post_ledger_entry(v_s.enrolment_id, 'adjustment', v_s.credit_adjustment_paisa, 'credit', null, app.fn_karachi_today(), 'fee_settlement', p_settlement_id);
  end if;
  if v_s.net_refund_paisa > 0 then
    perform public.post_ledger_entry(v_s.enrolment_id, 'refund', v_s.net_refund_paisa, 'debit', null, app.fn_karachi_today(), 'fee_settlement', p_settlement_id);
  end if;

  update public.fee_settlement
     set status = 'disbursed', disbursed_by = (select auth.uid()), disbursed_at = now(), instrument_type = p_instrument_type, instrument_ref = nullif(btrim(p_instrument_ref), '')
   where id = p_settlement_id;

  select coalesce(sum(case when direction = 'debit' then amount_paisa else -amount_paisa end), 0)::bigint into v_balance from public.fee_ledger where enrolment_id = v_s.enrolment_id;
  return jsonb_build_object('status', 'disbursed', 'ledger_balance_paisa', v_balance);
end;
$function$;

-- public.record_admission_fee_payment
create or replace function public.record_admission_fee_payment(p_offer_id uuid, p_amount_paisa bigint, p_mode public.fee_payment_mode, p_reference_no text default null::text)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_offer         public.admission_offer%rowtype;
  v_campus        uuid;
  v_status        public.admission_fee_payment_status;
  v_id            uuid;
  v_required      bigint;
  v_covered_paisa bigint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_amount_paisa <= 0 then
    raise exception 'AMOUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  select * into v_offer from public.admission_offer where id = p_offer_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_offer.status <> 'accepted' then
    raise exception 'OFFER_NOT_ACCEPTED' using errcode = '55000';
  end if;
  select campus_id into v_campus from public.admission_application where id = v_offer.application_id;
  perform app.fn_assert_campus_access(v_campus);

  v_status := case when p_mode in ('cash', 'online') then 'reconciled' else 'provisional' end;

  insert into public.admission_fee_payment (
    tenant_id, campus_id, offer_id, amount_paisa, mode, status, reference_no, recorded_by
  ) values (
    app.auth_tenant_id(), v_campus, p_offer_id, p_amount_paisa, p_mode, v_status, p_reference_no, auth.uid()
  )
  returning id into v_id;

  -- AC3: pause the expiry clock here, the moment enough money (some of
  -- it still unreconciled) is on record — not inside fn_enrol_from_offer,
  -- since a later exception raised from that same call would roll back
  -- this update along with everything else in that failed statement.
  if v_status = 'provisional' then
    v_required := round(v_offer.admission_fee_amount * 100)::bigint;
    select coalesce(sum(amount_paisa), 0) into v_covered_paisa from public.admission_fee_payment where offer_id = p_offer_id;
    if v_covered_paisa >= v_required then
      update public.admission_offer
         set expiry_paused_at = clock_timestamp(),
             expiry_pause_reason = 'Awaiting bank reconciliation of a provisionally received admission fee payment.'
       where id = p_offer_id and expiry_paused_at is null;
    end if;
  end if;

  return v_id;
end;
$function$;

-- public.waive_admission_fee
create or replace function public.waive_admission_fee(p_offer_id uuid, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_offer  public.admission_offer%rowtype;
  v_campus uuid;
  v_id     uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'REASON_TOO_SHORT' using errcode = '23514';
  end if;

  select * into v_offer from public.admission_offer where id = p_offer_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_offer.status <> 'accepted' then
    raise exception 'OFFER_NOT_ACCEPTED' using errcode = '55000';
  end if;
  select campus_id into v_campus from public.admission_application where id = v_offer.application_id;
  perform app.fn_assert_campus_access(v_campus);

  insert into public.admission_fee_waiver (tenant_id, campus_id, offer_id, reason, approved_by)
  values (app.auth_tenant_id(), v_campus, p_offer_id, btrim(p_reason), auth.uid())
  returning id into v_id;

  return v_id;
end;
$function$;

-- public.reconcile_admission_fee_payment
create or replace function public.reconcile_admission_fee_payment(p_payment_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_offer_id uuid;
  v_campus   uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select p.campus_id into v_campus from public.admission_fee_payment p where p.id = p_payment_id and p.tenant_id = app.auth_tenant_id();
  if found then
    perform app.fn_assert_campus_access(v_campus);
  end if;

  update public.admission_fee_payment
     set status = 'reconciled', reconciled_by = auth.uid(), reconciled_at = clock_timestamp()
   where id = p_payment_id and tenant_id = app.auth_tenant_id() and status = 'provisional'
  returning offer_id into v_offer_id;

  if not found then
    raise exception 'PAYMENT_NOT_RECONCILABLE' using errcode = '55000';
  end if;

  update public.admission_offer
     set expiry_paused_at = null, expiry_pause_reason = null
   where id = v_offer_id and expiry_paused_at is not null;
end;
$function$;

-- public.refund_hostel_deposit
create or replace function public.refund_hostel_deposit(p_deposit_id uuid, p_voucher_no text, p_refunded_on date default null::date)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_d    public.hostel_security_deposit%rowtype;
  v_head uuid;
  v_sess uuid;
  v_day  date := coalesce(p_refunded_on, app.fn_karachi_today());
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.hostel_security_deposit where id = p_deposit_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'DEPOSIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_d.campus_id);

  if v_d.refunded_on is not null then
    raise exception 'DEPOSIT_REFUNDED' using errcode = '22023';
  end if;
  if v_d.received_on is null then
    raise exception 'DEPOSIT_NOT_RECEIVED' using errcode = '22023';
  end if;
  if exists (select 1 from public.hostel_allocation a where a.student_id = v_d.student_id and (a.ends_on is null or a.ends_on >= v_day)) then
    raise exception 'STUDENT_STILL_HOUSED' using errcode = '22023';
  end if;
  if char_length(btrim(coalesce(p_voucher_no, ''))) < 3 then
    raise exception 'VOUCHER_REQUIRED' using errcode = '23514';
  end if;
  v_head := app.fn_hostel_fee_head(v_d.tenant_id, 'HOSTEL_DEPOSIT');
  select session_id into v_sess from public.enrolment where id = v_d.enrolment_id;
  insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction, value_date, source_type, source_id, reason, created_by)
  values (v_d.tenant_id, v_d.campus_id, v_d.enrolment_id, v_sess, 'adjustment', v_head, v_d.amount_paisa, 'credit', v_day, 'hostel_deposit_release', v_d.id,
          'Hostel security deposit released on leaving', (select auth.uid())),
         (v_d.tenant_id, v_d.campus_id, v_d.enrolment_id, v_sess, 'refund', v_head, v_d.amount_paisa, 'debit', v_day, 'hostel_deposit_refund', v_d.id,
          'Hostel security deposit refunded, voucher ' || btrim(p_voucher_no), (select auth.uid()));
  update public.hostel_security_deposit set refunded_on = v_day, refund_voucher_no = btrim(p_voucher_no) where id = p_deposit_id;
end;
$function$;

-- public.receive_hostel_deposit
create or replace function public.receive_hostel_deposit(p_deposit_id uuid, p_received_on date)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_d public.hostel_security_deposit%rowtype;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.hostel_security_deposit where id = p_deposit_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DEPOSIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_d.campus_id);

  if v_d.refunded_on is not null then
    raise exception 'DEPOSIT_REFUNDED' using errcode = '22023';
  end if;
  update public.hostel_security_deposit set received_on = coalesce(received_on, p_received_on) where id = p_deposit_id;
end;
$function$;

-- public.disburse_deposit_refund
create or replace function public.disburse_deposit_refund(p_enrolment_id uuid, p_instrument_type text, p_instrument_ref text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_d       public.security_deposit%rowtype;
  v_n_fees  bigint;
  v_n_other bigint;
  v_balance bigint;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_d from public.security_deposit where enrolment_id = p_enrolment_id and tenant_id = app.auth_tenant_id() and status = 'held' for update;
  if not found then
    raise exception 'NO_DEPOSIT_HELD' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_d.campus_id);

  if v_d.approved_at is null then
    raise exception 'REFUND_NOT_APPROVED' using errcode = '55000';
  end if;
  if p_instrument_type not in ('cash', 'cheque', 'transfer') or (p_instrument_type <> 'cash' and length(btrim(coalesce(p_instrument_ref, ''))) = 0) then
    raise exception 'INSTRUMENT_REFERENCE_REQUIRED' using errcode = '22023';
  end if;

  select coalesce(sum(i.netted_paisa) filter (where i.domain = 'fees'), 0), coalesce(sum(i.netted_paisa) filter (where i.domain <> 'fees'), 0)
    into v_n_fees, v_n_other
    from public.no_dues_item i join public.no_dues_clearance c on c.id = i.clearance_id
   where c.enrolment_id = p_enrolment_id and c.status = 'cleared';
  if v_n_fees + v_n_other <> v_d.netted_paisa then
    raise exception 'NETTING_MISMATCH' using errcode = '55000';
  end if;
  if v_n_fees > greatest(app.fn_enrolment_ledger_balance(p_enrolment_id), 0) then
    raise exception 'LEDGER_MOVED_SINCE_APPROVAL' using errcode = '55000', hint = 'The fee dues changed after the clearance; rebuild the checklist';
  end if;

  -- fees netted settles dues on the ledger; other-domain netting leaves the account untouched, so only the rest is released to it
  if v_d.amount_paisa - v_n_other > 0 then
    perform public.post_ledger_entry(p_enrolment_id, 'adjustment', v_d.amount_paisa - v_n_other, 'credit', null, app.fn_karachi_today(), 'security_deposit', v_d.id);
  end if;
  if v_d.refund_paisa > 0 then
    perform public.post_ledger_entry(p_enrolment_id, 'refund', v_d.refund_paisa, 'debit', null, app.fn_karachi_today(), 'security_deposit', v_d.id);
  end if;

  update public.security_deposit
     set status = case when v_d.refund_paisa > 0 then 'refunded' else 'adjusted' end,
         disbursed_by = (select auth.uid()), disbursed_at = now(), instrument_type = p_instrument_type, instrument_ref = nullif(btrim(p_instrument_ref), '')
   where id = v_d.id;

  v_balance := app.fn_enrolment_ledger_balance(p_enrolment_id);
  return jsonb_build_object('status', case when v_d.refund_paisa > 0 then 'refunded' else 'adjusted' end, 'refund_paisa', v_d.refund_paisa, 'ledger_balance_paisa', v_balance);
end;
$function$;

-- public.security_deposit_balance
create or replace function public.security_deposit_balance(p_enrolment_id uuid)
 returns bigint
 language plpgsql
 stable security definer
 set search_path = ''
as $function$
declare
  v_campus_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select e.campus_id into v_campus_id from public.enrolment e where e.id = p_enrolment_id and e.tenant_id = app.auth_tenant_id();
  if found then
    perform app.fn_assert_campus_access(v_campus_id);
  end if;
  return coalesce((select sum(d.amount_paisa - d.netted_paisa) from public.security_deposit d
                    where d.enrolment_id = p_enrolment_id and d.tenant_id = app.auth_tenant_id() and d.status = 'held'), 0)::bigint;
end;
$function$;

-- public.propose_fee_plan_override
create or replace function public.propose_fee_plan_override(p_line_id uuid, p_new_amount_paisa bigint, p_reason text)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REASON_REQUIRED' using errcode = '23514';
  end if;

  select fp.tenant_id, fp.campus_id into v_tenant_id, v_campus_id
    from public.fee_plan_line fpl join public.fee_plan fp on fp.id = fpl.plan_id
   where fpl.id = p_line_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FEE_PLAN_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_campus_id);

  update public.fee_plan_line
     set pending_amount_paisa = p_new_amount_paisa, override_reason = p_reason, override_status = 'pending_approval'
   where id = p_line_id;
end;
$function$;

-- public.remove_fee_plan_line
create or replace function public.remove_fee_plan_line(p_line_id uuid, p_reason text default null::text)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select fp.tenant_id, fp.campus_id into v_tenant_id, v_campus_id
    from public.fee_plan_line fpl join public.fee_plan fp on fp.id = fpl.plan_id
   where fpl.id = p_line_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FEE_PLAN_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_campus_id);

  update public.fee_plan_line
     set effective_to = (date_trunc('month', current_date) + interval '1 month - 1 day')::date
   where id = p_line_id and effective_to is null;
  if not found then
    raise exception 'ALREADY_REMOVED' using errcode = '55000';
  end if;
end;
$function$;

-- public.decide_fee_plan_override
create or replace function public.decide_fee_plan_override(p_line_id uuid, p_approve boolean)
 returns void
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_line public.fee_plan_line%rowtype;
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select fpl.* into v_line
    from public.fee_plan_line fpl join public.fee_plan fp on fp.id = fpl.plan_id
   where fpl.id = p_line_id and fp.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'FEE_PLAN_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  select fp.campus_id into v_campus_id from public.fee_plan fp where fp.id = v_line.plan_id;
  perform app.fn_assert_campus_access(v_campus_id);

  if v_line.override_status <> 'pending_approval' then
    raise exception 'OVERRIDE_NOT_PENDING' using errcode = '55000';
  end if;

  if p_approve then
    update public.fee_plan_line
       set amount_paisa = pending_amount_paisa, override_status = 'approved', approved_by = auth.uid(), approved_at = now()
     where id = p_line_id;
  else
    update public.fee_plan_line
       set pending_amount_paisa = null, override_status = 'rejected', approved_by = auth.uid(), approved_at = now()
     where id = p_line_id;
  end if;
end;
$function$;

-- public.build_fee_plan
create or replace function public.build_fee_plan(p_enrolment_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_campus_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select campus_id into v_campus_id from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_campus_access(v_campus_id);
  return app.build_fee_plan_for(p_enrolment_id, app.auth_tenant_id());
end;
$function$;

-- public.fn_enrol_from_offer
create or replace function public.fn_enrol_from_offer(p_offer_id uuid, p_gender public.gender, p_payment_id uuid default null::uuid, p_waiver_id uuid default null::uuid, p_name_ur text default null::text, p_father_name_en text default null::text, p_father_name_ur text default null::text, p_religion text default null::text, p_nationality text default 'PK'::text, p_b_form_no text default null::text, p_blood_group text default null::text, p_section_id uuid default null::uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_offer             public.admission_offer%rowtype;
  v_application       public.admission_application%rowtype;
  v_enquiry           public.admission_enquiry%rowtype;
  v_existing_enrolment public.enrolment%rowtype;
  v_payment           public.admission_fee_payment%rowtype;
  v_waiver            public.admission_fee_waiver%rowtype;
  v_section_id        uuid;
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

-- public.fn_quick_admission
create or replace function public.fn_quick_admission(p_campus_id uuid, p_session_id uuid, p_child_name text, p_dob date, p_gender public.gender, p_class_level_id uuid, p_section_id uuid, p_parent_name text, p_phone text, p_admission_fee numeric default 0, p_payment_mode text default 'cash'::text, p_payment_reference text default null::text, p_b_form_no text default null::text, p_father_name_en text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_tenant_id        uuid := app.auth_tenant_id();
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

  if v_fee_amount > 0 then
    insert into public.admission_fee_payment (
      tenant_id, campus_id, offer_id, amount_paisa, mode, reference_no,
      recorded_by, status, reconciled_at, reconciled_by
    ) values (
      v_tenant_id, p_campus_id, v_offer_id, v_fee_paisa, p_payment_mode::public.fee_payment_mode, p_payment_reference,
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
    'application_id', v_app_id,
    'enquiry_id', v_enquiry_id,
    'offer_id', v_offer_id
  );
end;
$function$;

-- app.fn_post_system_payment
create or replace function app.fn_post_system_payment(p_tenant_id uuid, p_enrolment_id uuid, p_amount bigint, p_mode public.fee_payment_mode, p_reference text, p_value_date date, p_bank_account_id uuid default null::uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path = ''
as $function$
declare
  v_prev text := current_setting('request.jwt.claims', true);
  v_id   uuid;
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object(
      'tenant_id', p_tenant_id,
      'app_role', 'accountant',
      'campus_ids', (select coalesce(json_agg(e.campus_id), '[]'::json) from public.enrolment e where e.id = p_enrolment_id and e.tenant_id = p_tenant_id)
    )::text,
    true
  );
  v_id := public.record_payment(p_enrolment_id, p_amount, p_mode, p_reference, p_value_date);
  if p_bank_account_id is not null then
    update public.fee_payment set bank_account_id = p_bank_account_id where id = v_id;
  end if;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  return v_id;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$function$;
