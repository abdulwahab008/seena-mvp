-- Migration: 20260801270000_transfer_certificate_dues_clearance_gate.sql
-- Module T: FR-T04: Dues clearance gate before TC release
--
-- Adds:
-- 1. fee_challan.student_id reference and idx_fee_challan_student_unpaid
-- 2. certificate_issue columns (override_reason, override_by, override_at)
-- 3. trg_require_override_reason enforcing min 20 chars when overridden
-- 4. public.get_clearance_summary(p_student_id uuid) returning dues breakdown
-- 5. Updated public.issue_transfer_certificate() with p_override_reason and clearance check

-- 1. Ensure fee_challan has student_id populated and indexed
alter table public.fee_challan
  add column if not exists student_id uuid references public.student(id);

update public.fee_challan fc
   set student_id = e.student_id
  from public.enrolment e
 where fc.enrolment_id = e.id
   and fc.student_id is null;

create or replace function public.tg_fee_challan_set_student_id()
returns trigger
language plpgsql
as $$
begin
  if new.student_id is null and new.enrolment_id is not null then
    select student_id into new.student_id from public.enrolment where id = new.enrolment_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fee_challan_set_student_id on public.fee_challan;
create trigger trg_fee_challan_set_student_id
  before insert or update on public.fee_challan
  for each row execute function public.tg_fee_challan_set_student_id();

create index if not exists idx_fee_challan_student_unpaid
  on public.fee_challan(student_id)
  where status <> 'paid';

-- 2. Add override fields to certificate_issue
alter table public.certificate_issue
  add column if not exists override_reason text,
  add column if not exists override_by uuid references auth.users(id),
  add column if not exists override_at timestamptz;

-- 3. Trigger & constraint requiring min 20 chars for override_reason
create or replace function public.trg_require_override_reason()
returns trigger
language plpgsql
as $$
begin
  if new.override_by is not null and (new.override_reason is null or length(btrim(new.override_reason)) < 20) then
    raise exception 'OVERRIDE_REASON_MIN_LENGTH_20' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_require_override_reason on public.certificate_issue;
create trigger trg_require_override_reason
  before insert or update on public.certificate_issue
  for each row execute function public.trg_require_override_reason();

-- 4. Clearance summary RPC
create or replace function public.get_clearance_summary(p_student_id uuid)
returns table(
  source text,
  description text,
  amount numeric,
  days_outstanding int
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role text := app.auth_role();
  v_has_access boolean;
begin
  -- Campus scope security check
  select exists (
    select 1
      from public.enrolment e
     where e.student_id = p_student_id
       and e.tenant_id = v_tenant_id
       and (
         v_role in ('super_admin', 'owner')
         or e.campus_id = any(app.auth_campus_ids())
       )
  ) into v_has_access;

  if not v_has_access then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- 1. Unpaid & Part-paid fee challans
  return query
  select
    'fee_challan'::text as source,
    format('Challan #%s (%s)', fc.challan_no, to_char(fc.billing_period, 'Mon YYYY'))::text as description,
    round(fc.net_paisa / 100.0, 2)::numeric as amount,
    greatest(0, (current_date - fc.due_date))::int as days_outstanding
  from public.fee_challan fc
  join public.enrolment e on e.id = fc.enrolment_id
  where (fc.student_id = p_student_id or e.student_id = p_student_id)
    and fc.tenant_id = v_tenant_id
    and fc.status in ('unpaid', 'part_paid')
    and fc.deleted_at is null
  order by fc.due_date asc;

  -- 2. Library loans guard
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'library_loan'
  ) then
    null;
  end if;

  -- 3. Transport ledger guard
  if exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = 'transport_ledger'
  ) then
    null;
  end if;

  return;
end;
$$;

revoke execute on function public.get_clearance_summary(uuid) from public, anon;
grant execute on function public.get_clearance_summary(uuid) to authenticated;

-- 5. Updated issue_transfer_certificate with dues clearance gate
drop function if exists public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language
);

create or replace function public.issue_transfer_certificate(
  p_enrolment_id uuid,
  p_leaving_date date,
  p_reason text default null,
  p_conduct text default null,
  p_board_code text default null,
  p_language public.certificate_language default 'en',
  p_override_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_uid         uuid := (select auth.uid());
  v_e           record;
  v_existing    record;
  v_template    public.certificate_template%rowtype;
  v_template_id uuid;
  v_signatory   text;
  v_identity    jsonb;
  v_identity_id uuid;
  v_seal        jsonb;
  v_issued_on   date := current_date;
  v_values      jsonb;
  v_snapshot    jsonb;
  v_serial      text;
  v_pdf_path    text;
  v_issue_id    uuid;
  v_unpaid_count int := 0;
  v_unpaid_paisa bigint := 0;
  v_dues_cleared boolean := true;
  v_override_by uuid := null;
  v_override_at timestamptz := null;
  v_clean_override text := null;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.tenant_id, e.campus_id, e.session_id, e.student_id,
         e.status::text as enrolment_status, e.joined_on, e.deleted_at,
         s.name_en, s.name_ur, s.father_name_en, s.father_name_ur, s.gr_number,
         s.dob, s.gender::text as gender, s.religion, s.b_form_no,
         s.deleted_at as student_deleted_at,
         cl.name_en as class_name,
         cs.name as section_name,
         sess.name as session_name,
         c.name as campus_name, c.name_ur as campus_name_ur, c.code as campus_code, c.city as campus_city,
         t.name as tenant_name, t.name_ur as tenant_name_ur
    into v_e
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
    join public.academic_session sess on sess.id = e.session_id
    join public.campus c on c.id = e.campus_id
    join public.tenant t on t.id = e.tenant_id
   where e.id = p_enrolment_id
     and e.tenant_id = v_tenant_id
   for update of e;

  if not found or v_e.deleted_at is not null or v_e.student_deleted_at is not null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_role not in ('super_admin', 'owner') and not (v_e.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select ci.id, ci.serial_no, ci.issued_at
    into v_existing
    from public.certificate_issue ci
   where ci.enrolment_id = p_enrolment_id
     and ci.certificate_type = 'transfer'
     and ci.status = 'issued'
   limit 1;
  if found then
    raise exception 'TC_ALREADY_ISSUED: %', v_existing.serial_no
      using errcode = '23505',
            detail = format('issue_id=%s serial_no=%s issued_at=%s',
                            v_existing.id, v_existing.serial_no, v_existing.issued_at),
            hint = 'Use Duplicate instead of issuing a second original.';
  end if;

  if v_e.enrolment_status <> 'active' then
    raise exception 'ENROLMENT_NOT_ACTIVE'
      using errcode = '55000',
            detail = format('enrolment_status=%s', v_e.enrolment_status),
            hint = 'A Transfer Certificate can only be issued for a student who is actually enrolled.';
  end if;

  if p_leaving_date is null or p_leaving_date < v_e.joined_on then
    raise exception 'LEAVING_DATE_BEFORE_ADMISSION'
      using errcode = '23514',
            detail = format('leaving_date=%s joined_on=%s', p_leaving_date, v_e.joined_on),
            hint = 'The leaving date cannot precede the date of admission.';
  end if;

  -- FR-T04: Dues clearance gate
  select count(*), coalesce(sum(fc.net_paisa), 0)
    into v_unpaid_count, v_unpaid_paisa
    from public.fee_challan fc
    join public.enrolment e on e.id = fc.enrolment_id
   where e.student_id = v_e.student_id
     and fc.tenant_id = v_tenant_id
     and fc.status in ('unpaid', 'part_paid')
     and fc.deleted_at is null;

  if v_unpaid_count > 0 then
    if p_override_reason is null or length(btrim(p_override_reason)) < 20 then
      raise exception 'UNPAID_DUES_OUTSTANDING'
        using errcode = '55000',
              detail = format('unpaid_challans=%s outstanding_amount=%s', v_unpaid_count, (v_unpaid_paisa / 100.0)),
              hint = 'Outstanding dues must be cleared before issuing a Transfer Certificate, or an override reason of at least 20 characters must be provided.';
    else
      v_override_by := v_uid;
      v_override_at := clock_timestamp();
      v_clean_override := btrim(p_override_reason);
      v_dues_cleared := false;
    end if;
  else
    v_dues_cleared := true;
  end if;

  v_template_id := public.resolve_certificate_template(
    v_e.campus_id, 'transfer'::public.certificate_type, p_board_code, p_language);
  if v_template_id is null then
    raise exception 'TEMPLATE_NOT_FOUND'
      using errcode = 'P0002',
            detail = format('campus_id=%s board_code=%s language=%s', v_e.campus_id, p_board_code, p_language),
            hint = 'Activate a Transfer Certificate template for this campus, board and language first.';
  end if;
  select * into v_template from public.certificate_template where id = v_template_id;

  select au.full_name into v_signatory
    from public.app_user au where au.user_id = v_uid;

  v_identity := public.resolve_signing_identity(v_e.campus_id);
  v_identity_id := (v_identity ->> 'signing_identity_id')::uuid;

  v_values := jsonb_build_object(
    'school.name_en',              v_e.tenant_name,
    'school.name_ur',              v_e.tenant_name_ur,
    'campus.name',                 v_e.campus_name,
    'campus.code',                 v_e.campus_code,
    'issue.date',                  to_char(v_issued_on, 'DD-MM-YYYY'),
    'issue.place',                 v_e.campus_city,
    'student.name_en',             v_e.name_en,
    'student.name_ur',             v_e.name_ur,
    'student.father_name_en',      v_e.father_name_en,
    'student.father_name_ur',      v_e.father_name_ur,
    'student.gr_number',           v_e.gr_number,
    'student.dob',                 to_char(v_e.dob, 'DD-MM-YYYY'),
    'student.dob_words',           public.dob_to_words(v_e.dob, v_template.language::text),
    'student.gender',              initcap(v_e.gender),
    'student.religion',            v_e.religion,
    'student.b_form_no',           v_e.b_form_no,
    'enrolment.class_name',        v_e.class_name,
    'enrolment.section_name',      v_e.section_name,
    'enrolment.session_name',      v_e.session_name,
    'enrolment.joined_on',         to_char(v_e.joined_on, 'DD-MM-YYYY'),
    'enrolment.left_on',           to_char(p_leaving_date, 'DD-MM-YYYY'),
    'transfer.reason',             p_reason,
    'transfer.last_class_studied', v_e.class_name,
    'transfer.conduct',            p_conduct,
    'transfer.dues_cleared',       case when v_dues_cleared then 'Yes' when v_clean_override is not null then 'Overridden' else 'No' end,
    'transfer.override_reason',    v_clean_override,
    'transfer.remarks',            null,
    'signatory.name',              coalesce(v_identity ->> 'holder_name', nullif(v_signatory, '')),
    'signatory.designation',       coalesce(v_identity ->> 'designation', initcap(replace(v_role, '_', ' ')))
  );

  v_serial := public.allocate_certificate_serial(
    v_e.campus_id, 'transfer'::public.certificate_type, v_e.session_id);
  v_values := v_values || jsonb_build_object('issue.serial_no', v_serial);

  v_pdf_path := v_e.tenant_id::text || '/' || v_e.campus_id::text || '/transfer/'
                || replace(v_serial, '/', '-') || '.pdf';

  v_seal := case when v_identity is null then null else
    v_identity || jsonb_build_object(
      'signature_anchor_x_mm', v_template.signature_anchor_x_mm::float8,
      'signature_anchor_y_mm', v_template.signature_anchor_y_mm::float8,
      'signature_width_mm',    v_template.signature_width_mm::float8,
      'stamp_anchor_x_mm',     v_template.stamp_anchor_x_mm::float8,
      'stamp_anchor_y_mm',     v_template.stamp_anchor_y_mm::float8,
      'stamp_width_mm',        v_template.stamp_width_mm::float8,
      'stamp_opacity',         v_template.stamp_opacity::float8
    )
  end;

  v_snapshot := jsonb_build_object(
    'template', jsonb_build_object(
      'id',               v_template.id,
      'certificate_type', v_template.certificate_type,
      'board_code',       v_template.board_code,
      'language',         v_template.language,
      'version',          v_template.version,
      'status',           'issued',
      'title',            v_template.title,
      'body_html',        v_template.body_html,
      'page_size',        v_template.page_size
    ),
    'tenant', jsonb_build_object('name', v_e.tenant_name, 'name_ur', v_e.tenant_name_ur),
    'campus', jsonb_build_object('name', v_e.campus_name, 'name_ur', v_e.campus_name_ur,
                                 'code', v_e.campus_code, 'city', v_e.campus_city),
    'letterhead_storage_path',
      (public.resolve_branding(v_e.campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path',
      (public.resolve_branding(v_e.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'seal', v_seal,
    'values', v_values
  );

  insert into public.certificate_issue (
    tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
    serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_by,
    signing_identity_id, override_reason, override_by, override_at
  ) values (
    v_e.tenant_id, v_e.campus_id, v_e.student_id, p_enrolment_id, v_e.session_id, 'transfer',
    v_serial, v_template.id, v_template.version, v_template.language, v_pdf_path, v_snapshot, v_uid,
    v_identity_id, v_clean_override, v_override_by, v_override_at
  )
  returning id into v_issue_id;

  update public.enrolment
     set status = 'transferred',
         left_on = p_leaving_date,
         tc_issued_at = clock_timestamp(),
         tc_certificate_issue_id = v_issue_id
   where id = p_enrolment_id;

  return jsonb_build_object(
    'issue_id',            v_issue_id,
    'serial_no',           v_serial,
    'pdf_path',            v_pdf_path,
    'certificate_type',    'transfer',
    'status',              'issued',
    'template_id',         v_template.id,
    'template_version',    v_template.version,
    'language',            v_template.language,
    'signing_identity_id', v_identity_id,
    'payload_snapshot',    v_snapshot,
    'override_reason',     v_clean_override,
    'dues_cleared',        v_dues_cleared
  );
end;
$$;

revoke execute on function public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language, text
) from public, anon;

grant execute on function public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language, text
) to authenticated;
