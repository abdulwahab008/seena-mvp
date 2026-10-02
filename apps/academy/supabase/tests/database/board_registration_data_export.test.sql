-- pgTAP tests for FR-T11: board registration data export.
--
--   AC1  a B-Form stored canonically (35202-1234567-8) against an FBISE
--        profile wanting 13 bare digits BLOCKS the export, lists every
--        offending row with field, current value and expected pattern, and
--        a one-click normalise clears exactly those.
--   AC2  a valid Punjab run produces the board's exact 24 headers in order,
--        DD/MM/YYYY dates, M/F gender and PM/PE/CS/COM/ART group codes.
--   AC3  a missing father CNIC is blocking for FBISE and warning-only for
--        AKU-EB, entirely by profile configuration.
--   AC4  regenerating writes a NEW board_export_run with row count,
--        checksum, generated_by and file path, and the previous file's row
--        is untouched and still downloadable.
--
-- Plus the properties the acceptance criteria do not state and a lost
-- school year depends on:
--
--   * normalising NEVER writes to public.student — the canonical dashed
--     form is what the constraint demands and what stays on the record;
--   * an unvalidated run cannot be exported or completed, because an empty
--     error table means "nobody has looked", not "clean";
--   * validation is idempotent, so the readiness dashboard can be
--     refreshed all day without doubling its own error count;
--   * a soft-deleted child and a left enrolment are excluded in SQL, not
--     by RLS — these functions are SECURITY DEFINER and bypass it;
--   * the board comes from FR-J01's resolver, so a class level split across
--     two boards refuses to guess;
--   * campus scope holds, including for the empty-campus_ids claim, and a
--     rival tenant and a parent see nothing.
begin;
select plan(63);

select public.provision_tenant('test-board-co', 'Board Co', 'owner@boardco.test');
select id as tenant_id from public.tenant where slug = 'test-board-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-board-rival', 'Board Rival', 'owner@boardrival.test');
select id as rival_id from public.tenant where slug = 'test-board-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@boardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Board Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@boardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'teacher@boardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'subject_teacher', 'A Teacher');

select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@boardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'parent_uid', :'tenant_id', 'parent', 'A Mother');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@boardrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

select id as class9  from public.class_level where tenant_id = :'tenant_id' and code = '9'  \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select id as class11 from public.class_level where tenant_id = :'tenant_id' and code = '11' \gset
select id as class12 from public.class_level where tenant_id = :'tenant_id' and code = '12' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_campus('SOUTH', 'Campus South', null) as campus_b \gset

-- The board a section sits on is FR-J01's resolver's answer, and the answer
-- comes from the stream. Three Punjab streams so AC2's group code map has
-- something real to map; one FBISE and one AKU-EB stream so AC3's two halves
-- are genuinely two profiles rather than two branches.
select public.create_stream('PPM', 'Pre-Medical',      'پری میڈیکل',  'PUNJAB'::public.board,  10::smallint) as str_p_pm \gset
select public.create_stream('PPE', 'Pre-Engineering',  'پری انجینئرنگ','PUNJAB'::public.board,  10::smallint) as str_p_pe \gset
select public.create_stream('PCS', 'Computer Science', 'کمپیوٹر سائنس','PUNJAB'::public.board,  10::smallint) as str_p_cs \gset
select public.create_stream('FPM', 'Pre-Medical',      'پری میڈیکل',  'FBISE'::public.board,   10::smallint) as str_f_pm \gset
select public.create_stream('APM', 'Pre-Medical',      'پری میڈیکل',  'AKU_EB'::public.board,  10::smallint) as str_a_pm \gset

select public.create_section(:'campus_a', :'session_a', :'class9',  'PM', 40) as sec_p_pm \gset
select public.create_section(:'campus_a', :'session_a', :'class9',  'PE', 40) as sec_p_pe \gset
select public.create_section(:'campus_a', :'session_a', :'class9',  'CS', 40) as sec_p_cs \gset
select public.create_section(:'campus_a', :'session_a', :'class10', 'A',  40) as sec_f \gset
select public.create_section(:'campus_a', :'session_a', :'class11', 'A',  40) as sec_a \gset
select public.create_section(:'campus_a', :'session_a', :'class12', 'A',  40) as sec_x_f \gset
select public.create_section(:'campus_a', :'session_a', :'class12', 'B',  40) as sec_x_p \gset

select public.set_section_stream(:'sec_p_pm', :'str_p_pm') as _s1 \gset
select public.set_section_stream(:'sec_p_pe', :'str_p_pe') as _s2 \gset
select public.set_section_stream(:'sec_p_cs', :'str_p_cs') as _s3 \gset
select public.set_section_stream(:'sec_f',    :'str_f_pm') as _s4 \gset
select public.set_section_stream(:'sec_a',    :'str_a_pm') as _s5 \gset
select public.set_section_stream(:'sec_x_f',  :'str_f_pm') as _s6 \gset
select public.set_section_stream(:'sec_x_p',  :'str_p_pm') as _s7 \gset

-- Class 9, Punjab: AC2's cohort. Everything present, so the only thing
-- standing between them and a file is trap 2's dash.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Ayesha Noor', p_dob => date '2010-03-14',
  p_gender => 'female'::public.gender, p_name_ur => 'عائشہ نور',
  p_father_name_en => 'Imran Noor', p_father_name_ur => 'عمران نور',
  p_religion => 'Islam', p_b_form_no => '35202-1234567-8') as st_p1 \gset
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Bilal Ahmed', p_dob => date '2010-05-02',
  p_gender => 'male'::public.gender, p_name_ur => 'بلال احمد',
  p_father_name_en => 'Kashif Ahmed', p_religion => 'Islam',
  p_b_form_no => '35202-1234567-9') as st_p2 \gset
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Chandni Rao', p_dob => date '2010-07-21',
  p_gender => 'female'::public.gender, p_name_ur => 'چاندنی راؤ',
  p_father_name_en => 'Sagheer Rao', p_religion => 'Hindu',
  p_b_form_no => '35202-1234568-0') as st_p3 \gset

-- Class 10, FBISE: AC1's cohort.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Danish Ali', p_dob => date '2009-01-11',
  p_gender => 'male'::public.gender, p_father_name_en => 'Zafar Ali',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-1') as st_f1 \gset
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Erum Shah', p_dob => date '2009-02-19',
  p_gender => 'female'::public.gender, p_father_name_en => 'Nadeem Shah',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-2') as st_f2 \gset
-- Soft-deleted below: must vanish from the file entirely.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Farhan Iqbal', p_dob => date '2009-03-08',
  p_gender => 'male'::public.gender, p_father_name_en => 'Iqbal Hussain',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-3') as st_f3 \gset
-- Enrolment forced to 'left' below: also must vanish.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Gulnaz Bibi', p_dob => date '2009-04-25',
  p_gender => 'female'::public.gender, p_father_name_en => 'Rashid Bibi',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-4') as st_f4 \gset

-- Class 11, AKU-EB: AC3's warning half plus the consent case.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Hina Baig', p_dob => date '2008-06-01',
  p_gender => 'female'::public.gender, p_father_name_en => 'Tariq Baig',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-5') as st_a1 \gset
-- No father guardian at all: this is AC3's "missing father CNIC".
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Imran Sethi', p_dob => date '2008-07-14',
  p_gender => 'male'::public.gender, p_father_name_en => 'Aslam Sethi',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-6') as st_a2 \gset
-- Guardian present, consent never given.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Javeria Malik', p_dob => date '2008-08-30',
  p_gender => 'female'::public.gender, p_father_name_en => 'Naveed Malik',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-7') as st_a3 \gset

-- Class 12, FBISE section: AC3's blocking half, same shape as st_a2.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Kamran Butt', p_dob => date '2007-09-09',
  p_gender => 'male'::public.gender, p_father_name_en => 'Shafiq Butt',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-8') as st_x1 \gset
-- Class 12, Punjab section: makes class 12 straddle two boards.
select public.create_student(
  p_campus_id => :'campus_a', p_name_en => 'Laraib Zia', p_dob => date '2007-10-10',
  p_gender => 'female'::public.gender, p_father_name_en => 'Zia Ullah',
  p_religion => 'Islam', p_b_form_no => '35202-1234568-9') as st_x2 \gset

select public.enrol_student(:'sec_p_pm', :'st_p1') as enr_p1 \gset
select public.enrol_student(:'sec_p_pe', :'st_p2') as enr_p2 \gset
select public.enrol_student(:'sec_p_cs', :'st_p3') as enr_p3 \gset
select public.enrol_student(:'sec_f',    :'st_f1') as enr_f1 \gset
select public.enrol_student(:'sec_f',    :'st_f2') as enr_f2 \gset
select public.enrol_student(:'sec_f',    :'st_f3') as enr_f3 \gset
select public.enrol_student(:'sec_f',    :'st_f4') as enr_f4 \gset
select public.enrol_student(:'sec_a',    :'st_a1') as enr_a1 \gset
select public.enrol_student(:'sec_a',    :'st_a2') as enr_a2 \gset
select public.enrol_student(:'sec_a',    :'st_a3') as enr_a3 \gset
select public.enrol_student(:'sec_x_f',  :'st_x1') as enr_x1 \gset
select public.enrol_student(:'sec_x_p',  :'st_x2') as enr_x2 \gset

reset role;
-- Roll numbers deliberately disagree with the alphabet, so an assertion on
-- file order cannot pass by accident on the name.
update public.enrolment set roll_no = 3 where id = :'enr_p1';
update public.enrolment set roll_no = 1 where id = :'enr_p2';
update public.enrolment set roll_no = 2 where id = :'enr_p3';
update public.enrolment set roll_no = 1 where id = :'enr_f1';
update public.enrolment set roll_no = 2 where id = :'enr_f2';

-- Fathers. CNIC is stored dashed by chk_guardian_cnic_format, exactly as
-- B-Form is — which is why both are normalisable rather than broken.
insert into public.guardian (id, tenant_id, cnic, name_en, phone_e164)
values (gen_random_uuid(), :'tenant_id', '35202-7654321-1', 'Imran Noor',    '+923001110001'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-2', 'Kashif Ahmed',  '+923001110002'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-3', 'Sagheer Rao',   '+923001110003'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-4', 'Zafar Ali',     '+923001110004'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-5', 'Nadeem Shah',   '+923001110005'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-6', 'Iqbal Hussain', '+923001110006'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-7', 'Rashid Bibi',   '+923001110007'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-8', 'Tariq Baig',    '+923001110008'),
       (gen_random_uuid(), :'tenant_id', '35202-7654321-9', 'Naveed Malik',  '+923001110009'),
       (gen_random_uuid(), :'tenant_id', '35202-7654322-0', 'Shafiq Butt',   '+923001110010'),
       (gen_random_uuid(), :'tenant_id', '35202-7654322-1', 'Zia Ullah',     '+923001110011');

select id as g_p1 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-1' \gset
select id as g_p2 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-2' \gset
select id as g_p3 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-3' \gset
select id as g_f1 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-4' \gset
select id as g_f2 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-5' \gset
select id as g_f3 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-6' \gset
select id as g_f4 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-7' \gset
select id as g_a1 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-8' \gset
select id as g_a3 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654321-9' \gset
select id as g_x1 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654322-0' \gset
select id as g_x2 from public.guardian where tenant_id = :'tenant_id' and cnic = '35202-7654322-1' \gset

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'st_p1', :'g_p1', 'father', true, true),
       (:'tenant_id', :'st_p2', :'g_p2', 'father', true, true),
       (:'tenant_id', :'st_p3', :'g_p3', 'father', true, true),
       (:'tenant_id', :'st_f1', :'g_f1', 'father', true, true),
       (:'tenant_id', :'st_f2', :'g_f2', 'father', true, true),
       (:'tenant_id', :'st_f3', :'g_f3', 'father', true, true),
       (:'tenant_id', :'st_f4', :'g_f4', 'father', true, true),
       (:'tenant_id', :'st_a1', :'g_a1', 'father', true, true),
       (:'tenant_id', :'st_a3', :'g_a3', 'father', true, true),
       (:'tenant_id', :'st_x2', :'g_x2', 'father', true, true);

-- st_a2 gets a MOTHER only: the father CNIC field resolves to null, which is
-- AC3's input. st_x1 likewise, so the two halves are the same shape.
insert into public.guardian (id, tenant_id, cnic, name_en)
values (gen_random_uuid(), :'tenant_id', null, 'Sethi Begum'),
       (gen_random_uuid(), :'tenant_id', null, 'Butt Begum');
select id as g_a2m from public.guardian where tenant_id = :'tenant_id' and name_en = 'Sethi Begum' \gset
select id as g_x1m from public.guardian where tenant_id = :'tenant_id' and name_en = 'Butt Begum' \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id', :'st_a2', :'g_a2m', 'mother', true, true),
       (:'tenant_id', :'st_x1', :'g_x1m', 'mother', true, true);

-- st_f4's enrolment has ended; st_f3 is in the recycle bin.
update public.enrolment set status = 'left', left_on = current_date where id = :'enr_f4';
update public.student set deleted_at = now() where id = :'st_f3';

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

-- Consent to share with the board: everyone except st_a3, who is the point.
select public.record_consent(:'st_p1'::uuid, 'third_party_data_sharing', :'g_p1'::uuid, 'granted', 'counter');
select public.record_consent(:'st_p2'::uuid, 'third_party_data_sharing', :'g_p2'::uuid, 'granted', 'counter');
select public.record_consent(:'st_p3'::uuid, 'third_party_data_sharing', :'g_p3'::uuid, 'granted', 'counter');
select public.record_consent(:'st_f1'::uuid, 'third_party_data_sharing', :'g_f1'::uuid, 'granted', 'counter');
select public.record_consent(:'st_f2'::uuid, 'third_party_data_sharing', :'g_f2'::uuid, 'granted', 'counter');
select public.record_consent(:'st_f3'::uuid, 'third_party_data_sharing', :'g_f3'::uuid, 'granted', 'counter');
select public.record_consent(:'st_f4'::uuid, 'third_party_data_sharing', :'g_f4'::uuid, 'granted', 'counter');
select public.record_consent(:'st_a1'::uuid, 'third_party_data_sharing', :'g_a1'::uuid, 'granted', 'counter');
select public.record_consent(:'st_a2'::uuid, 'third_party_data_sharing', :'g_a2m'::uuid, 'granted', 'counter');
select public.record_consent(:'st_x1'::uuid, 'third_party_data_sharing', :'g_x1m'::uuid, 'granted', 'counter');
select public.record_consent(:'st_x2'::uuid, 'third_party_data_sharing', :'g_x2'::uuid, 'granted', 'counter');

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- ── Profiles are data ───────────────────────────────────────────────────

select is(
  (select count(*)::int from public.board_profile where tenant_id is null and export_kind = 'registration'),
  6,
  'six platform board profiles ship with the software'
);

select is(
  (select jsonb_array_length(column_spec) from public.board_profile
    where tenant_id is null and board_code = 'PUNJAB' and export_kind = 'registration'),
  24,
  'AC2: the Punjab profile declares exactly 24 columns'
);

-- ── AC1: FBISE, class 10 ────────────────────────────────────────────────

select public.begin_board_export_run(:'campus_a', :'session_a', :'class10') as run_f \gset

select is(
  (select board_code::text from public.board_export_run where id = :'run_f'),
  'FBISE',
  'the board is resolved from the section stream by FR-J01''s resolver'
);

select throws_ok(
  format('select * from public.fn_board_export_rows(%L)', :'run_f'),
  '23514', 'EXPORT_NOT_VALIDATED',
  'a run nobody has validated cannot be exported — an empty error table is not a clean bill'
);

select is(
  (select count(*)::int from public.validate_board_export(:'run_f')
    where rule_code = 'BFORM_FORMAT'),
  2,
  'AC1: both class 10 candidates fail the FBISE B-Form pattern'
);

select is(
  (select current_value from public.board_export_row_error
    where run_id = :'run_f' and student_id = :'st_f1' and rule_code = 'BFORM_FORMAT'),
  '35202-1234568-1',
  'AC1: the error carries the value as stored, so the controller recognises it'
);

select is(
  (select expected from public.board_export_row_error
    where run_id = :'run_f' and student_id = :'st_f1' and rule_code = 'BFORM_FORMAT'),
  '13 digits, no dashes',
  'AC1: and the pattern the board expects, in words'
);

select is(
  (select field_path from public.board_export_row_error
    where run_id = :'run_f' and student_id = :'st_f1' and rule_code = 'BFORM_FORMAT'),
  'student.b_form_no',
  'AC1: named by field'
);

select ok(
  (select bool_and(normalisable) from public.board_export_row_error
    where run_id = :'run_f' and rule_code = 'BFORM_FORMAT'),
  'AC1: the one-click normalise is offered only because it would actually work'
);

select ok(
  (select bool_and(severity = 'blocking') from public.board_export_row_error
    where run_id = :'run_f' and rule_code = 'BFORM_FORMAT'),
  'AC1: and it blocks'
);

select throws_ok(
  format('select * from public.fn_board_export_rows(%L)', :'run_f'),
  '23514', 'EXPORT_BLOCKED',
  'AC1: the export is blocked while any row has a blocking error'
);

select is(
  (select count(*)::int from public.board_export_row_error where run_id = :'run_f'),
  (select count(*)::int from public.validate_board_export(:'run_f')),
  'validation is idempotent — the readiness dashboard can be refreshed all day'
);

-- The recycle bin and the ended enrolment are excluded in SQL, not by RLS:
-- validate_board_export is SECURITY DEFINER and RLS never runs for it.
select is(
  (select (fn ->> 'student_count')::int from public.fn_board_export_readiness(:'run_f') as fn),
  2,
  'a soft-deleted student and a left enrolment are both excluded from the cohort'
);

select is(
  (select count(*)::int from public.board_export_row_error
    where run_id = :'run_f' and student_id in (:'st_f3', :'st_f4')),
  0,
  'and neither of them can produce an error either'
);

select is(
  public.normalise_board_export_run(:'run_f'),
  4,
  'AC1: one click clears the four normalisable blocking errors (B-Form and father CNIC, two children)'
);

select is(
  (select count(*)::int from public.board_export_row_error
    where run_id = :'run_f' and severity = 'blocking'),
  0,
  'AC1: and nothing blocking is left'
);

select ok(
  (select normalise_applied and normalised_by is not null and normalised_at is not null
     from public.board_export_run where id = :'run_f'),
  'AC1: who approved reshaping 400 identity numbers, and when, is on the run'
);

select is(
  (select b_form_no from public.student where id = :'st_f1'),
  '35202-1234568-1',
  'normalising does NOT rewrite the student: canonical storage stays dashed, the file is formatted'
);

select is(
  (select cells[7] from public.fn_board_export_rows(:'run_f') where student_id = :'st_f1'),
  '3520212345681',
  'AC1: and the exported B-Form is 13 bare digits'
);

select is(
  (select cells[8] from public.fn_board_export_rows(:'run_f') where student_id = :'st_f1'),
  '3520276543214',
  'the father CNIC is formatted the same way, from the same canonical store'
);

-- ── AC4: completion and regeneration ────────────────────────────────────

select lives_ok(
  format('select public.complete_board_export_run(%L, 2, %L, %L)',
         :'run_f', 'tenant/run/FBISE-10.csv', 'abc123'),
  'a validated, unblocked run completes'
);

select ok(
  (select status = 'completed' and row_count = 2 and file_path = 'tenant/run/FBISE-10.csv'
          and checksum = 'abc123' and generated_by is not null and generated_at is not null
     from public.board_export_run where id = :'run_f'),
  'AC4: row count, checksum, generated_by and file path are all recorded'
);

select throws_ok(
  format('select public.complete_board_export_run(%L, 2, %L, %L)', :'run_f', 'x', 'y'),
  '23514', 'RUN_NOT_EDITABLE',
  'a completed run is terminal, so regenerating cannot overwrite it'
);

select public.begin_board_export_run(:'campus_a', :'session_a', :'class10') as run_f2 \gset

select isnt(:'run_f2'::uuid, :'run_f'::uuid, 'AC4: regenerating writes a NEW run row');

select is(
  (select file_path from public.board_export_run where id = :'run_f'),
  'tenant/run/FBISE-10.csv',
  'AC4: and the previous run still points at its own file, which remains downloadable'
);

-- ── AC2: Punjab, class 9 ────────────────────────────────────────────────

select public.begin_board_export_run(:'campus_a', :'session_a', :'class9') as run_p \gset
select public.validate_board_export(:'run_p');
select public.normalise_board_export_run(:'run_p') as _norm_p \gset

select is(
  (select count(*)::int from public.board_export_row_error
    where run_id = :'run_p' and severity = 'blocking'),
  0,
  'AC2: given all rows valid'
);

select is(
  array_length(public.fn_board_export_headers(:'run_p'), 1),
  24,
  'AC2: the file has the board''s exact 24 headers'
);

select is(
  public.fn_board_export_headers(:'run_p'),
  array['Sr. No.', 'GR No.', 'Candidate Name', 'Candidate Name Urdu', 'Father Name',
        'Father Name Urdu', 'Date of Birth', 'Gender', 'B-Form No.', 'Father CNIC',
        'Religion', 'Nationality', 'Group', 'Class', 'Section', 'Roll No.', 'Medium',
        'Session', 'Institution Name', 'Institution Code', 'District', 'Blood Group',
        'Contact No.', 'Address']::text[],
  'AC2: in the board''s exact order'
);

select is(
  (select cells[7] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p1'),
  '14/03/2010',
  'AC2: dates as DD/MM/YYYY'
);

select is(
  (select cells[8] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p1'),
  'F',
  'AC2: gender as F'
);

select is(
  (select cells[8] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p2'),
  'M',
  'AC2: gender as M'
);

select is(
  (select cells[13] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p1'),
  'PM',
  'AC2: Pre-Medical -> PM'
);

select is(
  (select cells[13] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p2'),
  'PE',
  'AC2: Pre-Engineering -> PE'
);

select is(
  (select cells[13] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p3'),
  'CS',
  'AC2: Computer Science -> CS'
);

reset role;
select is(
  app.fn_board_export_cell(
    '{"stream.name_en": "Commerce"}'::jsonb,
    '{"header": "Group", "source": "stream.name_en", "code_map": "group"}'::jsonb,
    'DD/MM/YYYY',
    (select code_map from public.board_profile
      where tenant_id is null and board_code = 'PUNJAB' and export_kind = 'registration')
  ),
  'COM',
  'AC2: Commerce -> COM'
);

select is(
  app.fn_board_export_cell(
    '{"stream.name_en": "Arts"}'::jsonb,
    '{"header": "Group", "source": "stream.name_en", "code_map": "group"}'::jsonb,
    'DD/MM/YYYY',
    (select code_map from public.board_profile
      where tenant_id is null and board_code = 'PUNJAB' and export_kind = 'registration')
  ),
  'ART',
  'AC2: Arts -> ART'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select is(
  (select array_agg(cells[1] order by cells[1]) from public.fn_board_export_rows(:'run_p')),
  array['1', '2', '3']::text[],
  'the serial column is the file''s own row number, stamped after the ordering is decided'
);

select is(
  (select cells[2] from public.fn_board_export_rows(:'run_p') where cells[1] = '1'),
  (select gr_number from public.student where id = :'st_p2'),
  'and the file is ordered by roll number, not by name'
);

select is(
  (select cells[4] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p1'),
  'عائشہ نور',
  'Urdu rides through the export intact'
);

select is(
  (select cells[3] from public.fn_board_export_rows(:'run_p') where student_id = :'st_p1'),
  'AYESHA NOOR',
  'and the upper transform applies to the English name'
);

-- ── AC3: the same missing father CNIC, two boards ───────────────────────

select public.begin_board_export_run(:'campus_a', :'session_a', :'class12', 'FBISE'::public.board) as run_x \gset
select public.validate_board_export(:'run_x');

select is(
  (select severity::text from public.board_export_row_error
    where run_id = :'run_x' and student_id = :'st_x1' and rule_code = 'FATHER_CNIC'),
  'blocking',
  'AC3: a missing father CNIC is a blocking error for FBISE'
);

select public.begin_board_export_run(:'campus_a', :'session_a', :'class11') as run_a \gset
select public.validate_board_export(:'run_a');

select is(
  (select severity::text from public.board_export_row_error
    where run_id = :'run_a' and student_id = :'st_a2' and rule_code = 'FATHER_CNIC'),
  'warning',
  'AC3: and warning-only for AKU-EB, per profile configuration'
);

-- ── Consent ─────────────────────────────────────────────────────────────

select is(
  (select count(*)::int from public.board_export_row_error
    where run_id = :'run_a' and rule_code = 'CONSENT_MISSING'),
  1,
  'a child whose guardians never agreed to third-party data sharing is named, not silently dropped'
);

select is(
  (select student_id from public.board_export_row_error
    where run_id = :'run_a' and rule_code = 'CONSENT_MISSING'),
  :'st_a3'::uuid,
  'and it is the right child'
);

select throws_ok(
  format('select * from public.fn_board_export_rows(%L)', :'run_a'),
  '23514', 'EXPORT_BLOCKED',
  'the missing consent blocks the file, weeks before the deadline'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select public.record_consent(:'st_a3'::uuid, 'third_party_data_sharing', :'g_a3'::uuid, 'granted', 'counter');
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.normalise_board_export_run(:'run_a') as _norm_a \gset

select is(
  (select count(*)::int from public.board_export_row_error
    where run_id = :'run_a' and rule_code = 'CONSENT_MISSING'),
  0,
  'once the guardian agrees the error clears'
);

select is(
  (select count(*)::int from public.fn_board_export_rows(:'run_a')),
  3,
  'AC3: and the warning-only missing CNIC does not stop the AKU-EB file'
);

select is(
  (select cells[6] from public.fn_board_export_rows(:'run_a') where student_id = :'st_a2'),
  '3520212345686',
  'the file still carries every candidate, including the one with the warning'
);

select throws_ok(
  format('select public.complete_board_export_run(%L, 1, %L, %L)', :'run_x', 'p', 'c'),
  '23514', 'EXPORT_BLOCKED',
  'a run with blocking errors cannot be marked complete either'
);

-- ── Board resolution and profile resolution ─────────────────────────────

select throws_ok(
  format('select public.begin_board_export_run(%L, %L, %L)', :'campus_a', :'session_a', :'class12'),
  '23514', 'BOARD_AMBIGUOUS',
  'a class level split across two boards refuses to guess which file this is'
);

select throws_ok(
  format('select public.begin_board_export_run(%L, %L, %L, %L)',
         :'campus_a', :'session_a', :'class9', 'CAMBRIDGE'),
  'P0002', 'BOARD_PROFILE_NOT_FOUND',
  'a board this software has no profile for says so rather than producing a wrong file'
);

reset role;
insert into public.board_profile (tenant_id, board_code, export_kind, label, effective_from, column_spec, validation_rules, code_map)
values (:'tenant_id', 'FBISE', 'registration', 'FBISE 2026 (tenant override)', date '2001-01-01',
        '[{"header": "ONLY", "source": "student.gr_number"}]'::jsonb, '[]'::jsonb, '{}'::jsonb);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.begin_board_export_run(:'campus_a', :'session_a', :'class10') as run_f3 \gset
select is(
  array_length(public.fn_board_export_headers(:'run_f3'), 1),
  1,
  'a tenant profile with a later effective_from beats the platform default — trap 1''s escape hatch'
);

-- ── Campus scope, RLS, tenant isolation ─────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_b'), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format('select public.begin_board_export_run(%L, %L, %L)', :'campus_a', :'session_a', :'class9'),
  '42501', 'FORBIDDEN',
  'an exam controller of another campus cannot begin a run for this one'
);

select throws_ok(
  format('select * from public.validate_board_export(%L)', :'run_p'),
  '42501', 'FORBIDDEN',
  'nor validate one'
);

-- The empty-claim trap: campus_ids '{}' must fail closed, and it does
-- because the test is the positive `= any(...)`, never `not (... = any('{}'))`.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format('select public.begin_board_export_run(%L, %L, %L)', :'campus_a', :'session_a', :'class9'),
  '42501', 'FORBIDDEN',
  'an empty campus_ids claim is denied, not granted everything'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  format('select public.begin_board_export_run(%L, %L, %L)', :'campus_a', :'session_a', :'class9'),
  '42501', 'FORBIDDEN',
  'a teacher cannot register a class for a board exam'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(*)::int from public.board_export_run),
  0,
  'a parent sees no board export runs at all'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(), 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.board_export_run),
  0,
  'and a rival tenant sees none of ours'
);

select is(
  (select count(*)::int from public.board_export_row_error),
  0,
  'nor any of our row errors'
);

select is(
  (select count(*)::int from public.board_profile where tenant_id is not null),
  0,
  'nor our tenant profile override, though the platform profiles are shared'
);

select ok(
  (select count(*)::int from public.board_profile where tenant_id is null) = 6,
  'the platform profiles are readable by every signed-in user'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select throws_ok(
  format('insert into public.board_export_run (tenant_id, campus_id, board_code, session_id, class_level_id, profile_id) values (%L, %L, %L, %L, %L, (select id from public.board_profile limit 1))',
         :'tenant_id', :'campus_a', 'FBISE', :'session_a', :'class9'),
  '42501', 'permission denied for table board_export_run',
  'board_export_run cannot be written to directly — every write goes through the definer functions'
);

select throws_ok(
  format('insert into public.board_profile (tenant_id, board_code, label, column_spec) values (%L, %L, %L, %L)',
         :'tenant_id', 'FBISE', 'hand-rolled', '[{"header":"X","source":"student.gr_number"}]'),
  '42501', 'permission denied for table board_profile',
  'and a board profile is written by a migration alone'
);

select * from finish();
rollback;
