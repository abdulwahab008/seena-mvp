-- FR-B17: gate enrolment on admission fee payment.
--
-- fee_payment / fee_ledger / concession_award all require a NOT NULL
-- enrolment_id (an enrolment must already exist), but this FR's whole
-- point is to collect the admission fee BEFORE an enrolment exists. Two
-- small staging tables carry the pre-enrolment money/waiver, scoped to
-- admission_offer instead of enrolment, and fn_enrol_from_offer()
-- consumes exactly one of them atomically alongside creating the
-- student/enrolment/fee_ledger rows, rather than loosening the existing
-- ledger tables' invariants for this one caller.
--
--   * admission_fee_payment: cash/online payments are immediately
--     'reconciled' (money counted in hand); bank_challan/cheque start
--     'provisional' until fn_reconcile_admission_fee_payment() confirms
--     against the bank statement, matching this market's real
--     3-copy-challan workflow (see the FR-K11 migration header).
--   * admission_fee_waiver: an approval-role-only escape hatch for a
--     100% hardship/staff-child concession — recording a full
--     concession_scheme-driven waiver against a not-yet-existing
--     enrolment would need the same enrolment_id relaxation, so this
--     stays a minimal, purpose-built record rather than reusing
--     concession_award.
--   * admission_offer gains an expiry-pause pair so a provisionally-
--     received-but-unreconciled payment blocks enrolment without also
--     letting the offer silently lapse out from under the family while
--     the bank statement catches up; fn_expire_offers() is amended to
--     skip paused offers.
--   * The enquiry/application pipeline never collects gender (or the
--     other optional identity fields create_student() accepts), so
--     fn_enrol_from_offer() takes them as parameters, same as the
--     existing walk-in admit-student flow does.
--   * fn_enrol_from_offer() cannot simply call the existing
--     create_student()/enrol_student() — create_student()'s role check
--     excludes 'accountant', who this FR explicitly names as a caller —
--     so it inlines the same GR-allocation/insert logic instead of
--     composing those two functions.
--   * The expiry-clock pause is applied by record_admission_fee_payment()
--     itself, the moment a provisional payment brings the offer's total
--     up to the required amount — NOT by fn_enrol_from_offer() when it
--     later hits that state and raises PAYMENT_NOT_RECONCILED. A
--     raised, uncaught exception aborts the whole statement/transaction
--     it occurred in, which would silently roll back an update made
--     earlier in that same doomed call — pgTAP's throws_ok caught this
--     exact bug (its own EXCEPTION-block savepoint made the discarded
--     update visible as "never happened").

create type public.admission_fee_payment_status as enum ('provisional', 'reconciled');

create table public.admission_fee_payment (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenant(id) on delete cascade,
  campus_id                 uuid not null references public.campus(id) on delete cascade,
  offer_id                  uuid not null references public.admission_offer(id) on delete cascade,
  amount_paisa              bigint not null check (amount_paisa > 0),
  mode                      public.fee_payment_mode not null,
  status                    public.admission_fee_payment_status not null,
  reference_no              text,
  recorded_by               uuid references public.app_user(user_id),
  recorded_at               timestamptz not null default clock_timestamp(),
  reconciled_by             uuid references public.app_user(user_id),
  reconciled_at             timestamptz,
  consumed_by_enrolment_id  uuid references public.enrolment(id)
);
create index idx_admission_fee_payment_offer on public.admission_fee_payment (offer_id);

create table public.admission_fee_waiver (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenant(id) on delete cascade,
  campus_id                 uuid not null references public.campus(id) on delete cascade,
  offer_id                  uuid not null references public.admission_offer(id) on delete cascade,
  reason                    text not null,
  approved_by               uuid references public.app_user(user_id),
  approved_at               timestamptz not null default clock_timestamp(),
  consumed_by_enrolment_id  uuid references public.enrolment(id),
  constraint chk_waiver_reason_len check (length(btrim(reason)) >= 10)
);
create index idx_admission_fee_waiver_offer on public.admission_fee_waiver (offer_id);

alter table public.admission_offer add column expiry_paused_at timestamptz;
alter table public.admission_offer add column expiry_pause_reason text;

alter table public.enrolment add column admission_offer_id uuid references public.admission_offer(id);
alter table public.enrolment add column admission_fee_payment_id uuid references public.admission_fee_payment(id);
alter table public.enrolment add column admission_fee_waiver_id uuid references public.admission_fee_waiver(id);
create unique index uq_enrolment_admission_offer on public.enrolment (admission_offer_id) where admission_offer_id is not null;

create trigger admission_fee_payment_audit after insert or update or delete on public.admission_fee_payment
  for each row execute function app.tg_audit_row();
create trigger admission_fee_waiver_audit after insert or update or delete on public.admission_fee_waiver
  for each row execute function app.tg_audit_row();

-- ── fn_expire_offers(): unchanged sweep behaviour, plus skip paused ──

create or replace function public.fn_expire_offers()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  with expired as (
    update public.admission_offer
       set status = 'lapsed'
     where status = 'issued' and expires_at < now() and expiry_paused_at is null
    returning application_id
  )
  update public.admission_application a
     set status = 'lapsed'
    from expired
   where a.id = expired.application_id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.fn_expire_offers() from public, anon, authenticated;
grant execute on function public.fn_expire_offers() to service_role;

-- ── recording money against an offer ──────────────────────────────────

create or replace function public.record_admission_fee_payment(
  p_offer_id uuid,
  p_amount_paisa bigint,
  p_mode public.fee_payment_mode,
  p_reference_no text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke execute on function public.record_admission_fee_payment(uuid, bigint, public.fee_payment_mode, text) from public, anon;
grant execute on function public.record_admission_fee_payment(uuid, bigint, public.fee_payment_mode, text) to authenticated;

create or replace function public.reconcile_admission_fee_payment(p_payment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
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
$$;

revoke execute on function public.reconcile_admission_fee_payment(uuid) from public, anon;
grant execute on function public.reconcile_admission_fee_payment(uuid) to authenticated;

create or replace function public.waive_admission_fee(p_offer_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
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

  insert into public.admission_fee_waiver (tenant_id, campus_id, offer_id, reason, approved_by)
  values (app.auth_tenant_id(), v_campus, p_offer_id, btrim(p_reason), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.waive_admission_fee(uuid, text) from public, anon;
grant execute on function public.waive_admission_fee(uuid, text) to authenticated;

-- ── the gate itself ────────────────────────────────────────────────────

create or replace function public.fn_enrol_from_offer(
  p_offer_id uuid,
  p_gender public.gender,
  p_payment_id uuid default null,
  p_waiver_id uuid default null,
  p_name_ur text default null,
  p_father_name_en text default null,
  p_father_name_ur text default null,
  p_religion text default null,
  p_nationality text default 'PK',
  p_b_form_no text default null,
  p_blood_group text default null,
  p_section_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
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
$$;

revoke execute on function public.fn_enrol_from_offer(uuid, public.gender, uuid, uuid, text, text, text, text, text, text, text, uuid) from public, anon;
grant execute on function public.fn_enrol_from_offer(uuid, public.gender, uuid, uuid, text, text, text, text, text, text, text, uuid) to authenticated;

-- ── read access ─────────────────────────────────────────────────────

alter table public.admission_fee_payment enable row level security;
alter table public.admission_fee_waiver enable row level security;

create policy admission_fee_payment_tenant_read on public.admission_fee_payment
  for select to authenticated using (tenant_id = app.auth_tenant_id());
create policy admission_fee_waiver_tenant_read on public.admission_fee_waiver
  for select to authenticated using (tenant_id = app.auth_tenant_id());
