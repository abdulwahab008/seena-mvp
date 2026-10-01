-- FR-T07: School Leaving Certificate issuance.
--
-- A Leaving Certificate is for a student who COMPLETED Grade 10 or 12, not one
-- who transferred mid-session. Schools say TC, SLC and Leaving Certificate
-- interchangeably, but the printed wording differs and receiving institutions
-- notice, so it is a distinct certificate_type ('leaving') with a distinct
-- serial series (SLC-<year>-<seq>) rather than a mixed register.
--
--   * assert_terminal_class(enrolment) refuses any class other than 10 or 12
--     with the plain sentence the clerk needs: "Grade 8 leavers require a
--     Transfer Certificate, not a Leaving Certificate".
--   * A student who is not passed_out is refused; a student struck off in a
--     board class who never sat the board exam is refused and pointed to a
--     Transfer Certificate. (A struck-off student who DID register for the
--     exam is issued one: they completed the course.)
--   * The board, roll number and group come from exam_registration, the result
--     from board_result. "Result Awaited" is the normal state for months after
--     the exam, so it is a first-class value printed in the certificate, never
--     a blank and never a blocker.
--
-- exam_registration and board_result are the board-examination tables the
-- Exams module owns. They are created here only if absent, with the columns this
-- feature reads, and every column is added with ADD COLUMN IF NOT EXISTS so a
-- fuller definition from elsewhere is left intact.
--
-- The generic issuing core (app.fn_issue_certificate_core) is shared with the
-- Bonafide certificate (FR-T06). It is the issue_character_certificate body with
-- the type-specific fields passed in, so every type gets the same serial
-- allocation, template resolution, seal and snapshot behaviour.

create table if not exists public.exam_registration (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  student_id     uuid references public.student(id),
  enrolment_id   uuid references public.enrolment(id),
  board_code     text,
  roll_no        text,
  group_code     text,
  created_at     timestamptz not null default now()
);
alter table public.exam_registration add column if not exists tenant_id uuid references public.tenant(id) on delete cascade;
alter table public.exam_registration add column if not exists campus_id uuid references public.campus(id) on delete cascade;
alter table public.exam_registration add column if not exists student_id uuid references public.student(id);
alter table public.exam_registration add column if not exists enrolment_id uuid references public.enrolment(id);
alter table public.exam_registration add column if not exists board_code text;
alter table public.exam_registration add column if not exists roll_no text;
alter table public.exam_registration add column if not exists group_code text;
alter table public.exam_registration add column if not exists created_at timestamptz not null default now();
create index if not exists idx_exam_registration_enrolment on public.exam_registration (enrolment_id, board_code);
create index if not exists idx_exam_registration_tenant on public.exam_registration (tenant_id, campus_id);
alter table public.exam_registration enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'exam_registration') then
    create policy exam_reg_campus_scope on public.exam_registration for select to authenticated
      using (tenant_id = app.auth_tenant_id()
             and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'admissions_officer', 'accountant')
             and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
  end if;
end;
$$;

create table if not exists public.board_result (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  registration_id uuid not null references public.exam_registration(id) on delete cascade,
  result_status   text not null default 'awaited',
  imported_at     timestamptz not null default now()
);
alter table public.board_result add column if not exists registration_id uuid references public.exam_registration(id) on delete cascade;
alter table public.board_result add column if not exists result_status text not null default 'awaited';
create index if not exists idx_board_result_registration on public.board_result (registration_id);
alter table public.board_result enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'board_result') then
    create policy board_result_campus_scope on public.board_result for select to authenticated
      using (tenant_id = app.auth_tenant_id()
             and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller', 'admissions_officer')
             and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
  end if;
end;
$$;

-- ── field catalogue and serial series ──────────────────────────────────

insert into public.certificate_type_field_catalog (certificate_type, field_path, required, label_en, sample_en, sample_ur)
select 'leaving'::public.certificate_type, c.field_path, c.field_path in ('student.name_en', 'student.gr_number', 'issue.date'), c.label_en, c.sample_en, c.sample_ur
  from public.certificate_type_field_catalog c
 where c.certificate_type = 'bonafide' and c.field_path not like 'bonafide.%'
on conflict do nothing;

insert into public.certificate_type_field_catalog (certificate_type, field_path, required, label_en, sample_en, sample_ur) values
  ('leaving', 'leaving.board',           true,  'Examining board',     'FBISE',          'ایف بی آئی ایس ای'),
  ('leaving', 'leaving.roll_no',         false, 'Board roll number',   '462119',         '462119'),
  ('leaving', 'leaving.group',           false, 'Group',               'Pre-Medical',    'پری میڈیکل'),
  ('leaving', 'leaving.class_roman',     true,  'Class (roman)',       'XII',            'XII'),
  ('leaving', 'leaving.result_status',   true,  'Result status',       'Result Awaited', 'نتیجہ کا انتظار'),
  ('leaving', 'leaving.completion_date', false, 'Date of completion',  '31 March 2026',  '۳۱ مارچ ۲۰۲۶')
on conflict do nothing;

create or replace function app.certificate_serial_default_pattern(p_certificate_type public.certificate_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_certificate_type
           when 'transfer'  then 'TC-{YEAR}-{SEQ}'
           when 'character' then 'CC-{YEAR}-{SEQ}'
           when 'leaving'   then 'SLC-{YEAR}-{SEQ}'
           else                  'BC-{YEAR}-{SEQ}'
         end;
$$;
revoke execute on function app.certificate_serial_default_pattern(public.certificate_type) from public, anon, authenticated;

create unique index uq_one_active_leaving on public.certificate_issue (enrolment_id)
  where certificate_type = 'leaving' and status = 'issued';

-- ── the shared issuing core ────────────────────────────────────────────
-- Role checks belong to the public wrappers; this validates tenant and campus
-- scope, then does what every certificate issue does.

create or replace function app.fn_issue_certificate_core(
  p_student_id uuid, p_enrolment_id uuid, p_type public.certificate_type, p_extra jsonb,
  p_board_code text, p_language public.certificate_language
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
  v_s           record;
  v_e           record;
  v_session     record;
  v_span        jsonb;
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
begin
  select s.tenant_id, s.campus_id, s.deleted_at,
         s.name_en, s.name_ur, s.father_name_en, s.father_name_ur, s.gr_number,
         s.dob, s.gender::text as gender, s.religion, s.b_form_no,
         c.name as campus_name, c.name_ur as campus_name_ur, c.code as campus_code, c.city as campus_city,
         t.name as tenant_name, t.name_ur as tenant_name_ur
    into v_s
    from public.student s
    join public.campus c on c.id = s.campus_id
    join public.tenant t on t.id = s.tenant_id
   where s.id = p_student_id and s.tenant_id = v_tenant_id;
  if not found or v_s.deleted_at is not null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_s.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.id, cl.name_en as class_name, cs.name as section_name, sess.name as session_name
    into v_e
    from public.enrolment e
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
    join public.academic_session sess on sess.id = e.session_id
   where e.student_id = p_student_id and e.deleted_at is null
     and (p_enrolment_id is null or e.id = p_enrolment_id)
   order by e.joined_on desc, sess.starts_on desc
   limit 1;

  select s2.id, s2.name into v_session
    from public.academic_session s2
   where s2.tenant_id = v_tenant_id and s2.is_current and (s2.campus_id = v_s.campus_id or s2.campus_id is null)
   order by (s2.campus_id is not null) desc limit 1;
  if not found then
    raise exception 'ACADEMIC_SESSION_NOT_FOUND' using errcode = 'P0002',
      hint = 'A certificate serial belongs to an academic session; the campus has no current one.';
  end if;

  v_template_id := public.resolve_certificate_template(v_s.campus_id, p_type, p_board_code, p_language);
  if v_template_id is null then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002',
      detail = format('campus_id=%s type=%s board_code=%s language=%s', v_s.campus_id, p_type, p_board_code, p_language),
      hint = 'Activate a template of this certificate type for the campus, board and language first.';
  end if;
  select * into v_template from public.certificate_template where id = v_template_id;

  select au.full_name into v_signatory from public.app_user au where au.user_id = v_uid;
  v_identity := public.resolve_signing_identity(v_s.campus_id);
  v_identity_id := (v_identity ->> 'signing_identity_id')::uuid;
  v_span := public.student_attendance_span(p_student_id);

  v_values := jsonb_build_object(
    'school.name_en',            v_s.tenant_name,
    'school.name_ur',            v_s.tenant_name_ur,
    'campus.name',               v_s.campus_name,
    'campus.code',               v_s.campus_code,
    'issue.date',                to_char(v_issued_on, 'DD-MM-YYYY'),
    'issue.place',               v_s.campus_city,
    'student.name_en',           v_s.name_en,
    'student.name_ur',           v_s.name_ur,
    'student.father_name_en',    v_s.father_name_en,
    'student.father_name_ur',    v_s.father_name_ur,
    'student.gr_number',         v_s.gr_number,
    'student.dob',               to_char(v_s.dob, 'DD-MM-YYYY'),
    'student.dob_words',         public.dob_to_words(v_s.dob, v_template.language::text),
    'student.gender',            initcap(v_s.gender),
    'student.religion',          v_s.religion,
    'student.b_form_no',         v_s.b_form_no,
    'enrolment.class_name',      v_e.class_name,
    'enrolment.section_name',    v_e.section_name,
    'enrolment.session_name',    v_e.session_name,
    'enrolment.joined_on',       to_char((v_span ->> 'period_from')::date, 'DD-MM-YYYY'),
    'signatory.name',            coalesce(v_identity ->> 'holder_name', nullif(v_signatory, '')),
    'signatory.designation',     coalesce(v_identity ->> 'designation', initcap(replace(v_role, '_', ' ')))
  ) || coalesce(p_extra, '{}'::jsonb);

  v_serial := public.allocate_certificate_serial(v_s.campus_id, p_type, v_session.id);
  v_values := v_values || jsonb_build_object('issue.serial_no', v_serial);
  v_pdf_path := v_s.tenant_id::text || '/' || v_s.campus_id::text || '/' || p_type::text || '/' || replace(v_serial, '/', '-') || '.pdf';

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
      'id', v_template.id, 'certificate_type', v_template.certificate_type, 'board_code', v_template.board_code,
      'language', v_template.language, 'version', v_template.version, 'status', 'issued', 'title', v_template.title,
      'body_html', v_template.body_html, 'page_size', v_template.page_size
    ),
    'tenant', jsonb_build_object('name', v_s.tenant_name, 'name_ur', v_s.tenant_name_ur),
    'campus', jsonb_build_object('name', v_s.campus_name, 'name_ur', v_s.campus_name_ur, 'code', v_s.campus_code, 'city', v_s.campus_city),
    'letterhead_storage_path', (public.resolve_branding(v_s.campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path', (public.resolve_branding(v_s.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'seal', v_seal,
    'values', v_values
  );

  insert into public.certificate_issue (
    tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
    serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_by, signing_identity_id
  ) values (
    v_s.tenant_id, v_s.campus_id, p_student_id, v_e.id, v_session.id, p_type,
    v_serial, v_template.id, v_template.version, v_template.language, v_pdf_path, v_snapshot, v_uid, v_identity_id
  )
  returning id into v_issue_id;

  return jsonb_build_object(
    'issue_id', v_issue_id, 'serial_no', v_serial, 'pdf_path', v_pdf_path, 'certificate_type', p_type, 'status', 'issued',
    'template_id', v_template.id, 'template_version', v_template.version, 'language', v_template.language,
    'signing_identity_id', v_identity_id, 'payload_snapshot', v_snapshot
  );
end;
$$;
revoke execute on function app.fn_issue_certificate_core(uuid, uuid, public.certificate_type, jsonb, text, public.certificate_language) from public, anon, authenticated;

-- ── terminal class rule ────────────────────────────────────────────────

create or replace function public.assert_terminal_class(p_enrolment_id uuid)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_code text;
begin
  select cl.code into v_code
    from public.enrolment e join public.class_level cl on cl.id = e.class_level_id
   where e.id = p_enrolment_id and e.tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_code not in ('10', '12') then
    raise exception 'Grade % leavers require a Transfer Certificate, not a Leaving Certificate', v_code
      using errcode = '22023', hint = 'USE_TRANSFER_CERTIFICATE';
  end if;
end;
$$;
revoke execute on function public.assert_terminal_class(uuid) from public, anon;
grant execute on function public.assert_terminal_class(uuid) to authenticated;

-- ── issuing ────────────────────────────────────────────────────────────

create or replace function public.issue_leaving_certificate(p_enrolment_id uuid, p_language public.certificate_language default 'en')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_e         record;
  v_reg       record;
  v_result    text;
  v_res_label text;
  v_extra     jsonb;
  v_out       jsonb;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.id, e.student_id, e.campus_id, e.left_on, cl.code as class_code, s.status::text as student_status, sess.ends_on
    into v_e
    from public.enrolment e
    join public.class_level cl on cl.id = e.class_level_id
    join public.student s on s.id = e.student_id
    join public.academic_session sess on sess.id = e.session_id
   where e.id = p_enrolment_id and e.tenant_id = v_tenant_id and e.deleted_at is null;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_e.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  perform public.assert_terminal_class(p_enrolment_id);

  select r.id, r.board_code, r.roll_no, r.group_code into v_reg
    from public.exam_registration r
   where r.enrolment_id = p_enrolment_id and r.tenant_id = v_tenant_id
   order by r.created_at desc limit 1;

  if v_e.student_status = 'struck_off' then
    if v_reg.id is null or coalesce(btrim(v_reg.roll_no), '') = '' then
      raise exception 'Student was struck off without sitting the board examination; issue a Transfer Certificate instead'
        using errcode = '22023', hint = 'USE_TRANSFER_CERTIFICATE';
    end if;
  elsif v_e.student_status <> 'passed_out' then
    raise exception 'STUDENT_NOT_COMPLETED' using errcode = '22023',
      detail = format('status=%s', v_e.student_status),
      hint = 'A Leaving Certificate is for a student who has completed the class. Use a Transfer Certificate for a student who is leaving mid-course.';
  end if;

  select b.result_status into v_result
    from public.board_result b where b.registration_id = v_reg.id order by b.imported_at desc limit 1;
  v_res_label := case lower(coalesce(v_result, 'awaited'))
                   when 'passed' then 'Passed'
                   when 'failed' then 'Failed'
                   when 'compartment' then 'Compartment'
                   when 'withheld' then 'Result Withheld'
                   else 'Result Awaited' end;

  v_extra := jsonb_build_object(
    'leaving.board',           coalesce(nullif(btrim(v_reg.board_code), ''), 'Not recorded'),
    'leaving.roll_no',         coalesce(nullif(btrim(v_reg.roll_no), ''), 'Not recorded'),
    'leaving.group',           case when v_reg.group_code is null then null else initcap(replace(v_reg.group_code, '_', '-')) end,
    'leaving.class_roman',     case v_e.class_code when '10' then 'X' else 'XII' end,
    'leaving.result_status',   v_res_label,
    'leaving.completion_date', to_char(coalesce(v_e.left_on, v_e.ends_on), 'DD-MM-YYYY')
  );

  v_out := app.fn_issue_certificate_core(v_e.student_id, p_enrolment_id, 'leaving'::public.certificate_type, v_extra, v_reg.board_code, p_language);
  return v_out || jsonb_build_object('result_status', v_res_label);
exception when unique_violation then
  raise exception 'LEAVING_CERTIFICATE_ALREADY_ISSUED' using errcode = '23505',
    hint = 'This enrolment already has a live Leaving Certificate. Withdraw it with a reason before issuing a replacement.';
end;
$$;
revoke execute on function public.issue_leaving_certificate(uuid, public.certificate_language) from public, anon;
grant execute on function public.issue_leaving_certificate(uuid, public.certificate_language) to authenticated;
