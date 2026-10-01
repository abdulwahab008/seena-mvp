-- pgTAP tests for FR-J15 (amended report card after a correction) and FR-G15 (attendance snapshot on the card).
-- Fixture: the report-card suite's section of four candidates and a Final term.
begin;
select no_plan();

select public.provision_tenant('test-card-co', 'Card Co', 'owner@cardco.test');
select id as tenant_id from public.tenant where slug = 'test-card-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-card-rival', 'Card Rival', 'owner@cardrival.test');
select id as rival_id from public.tenant where slug = 'test-card-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@cardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Card Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@cardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@cardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'accounts@cardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'accountant', 'Accounts Clerk');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@cardrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

-- AC1's arithmetic, out of 800 across four papers of 200 so the aggregate is
-- 612 of 800 at 76.50% exactly as the acceptance criterion writes it.
select public.create_subject('ENG', 'English', 'انگریزی') as subj_eng \gset
select public.create_subject('URD', 'Urdu',    'اردو')    as subj_urd \gset
select public.create_subject('MTH', 'Maths',   'ریاضی')   as subj_mth \gset
select public.create_subject('SCI', 'Science', 'سائنس')   as subj_sci \gset

select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_eng', 6::smallint) as cs_eng \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_urd', 6::smallint) as cs_urd \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_mth', 6::smallint) as cs_mth \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class5', :'subj_sci', 6::smallint) as cs_sci \gset

select public.create_section(:'campus_a', :'session_a', :'class5', 'A', 40) as sec_a \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL', 'Final Term', 1::smallint, 100.00) as term_f \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _act_terms \gset

select public.upsert_exam_subject(:'term_f', :'cs_eng', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_eng \gset
select public.upsert_exam_subject(:'term_f', :'cs_urd', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_urd \gset
select public.upsert_exam_subject(:'term_f', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth \gset
select public.upsert_exam_subject(:'term_f', :'cs_sci', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_sci \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.save_grading_scheme(
  'FBISE'::public.board, 'FBISE 2025', date '2000-01-01',
  '[{"grade_label":"A1","min_pct":80,"max_pct":100,"gpa_point":4.00},
    {"grade_label":"A", "min_pct":70,"max_pct":79.99,"gpa_point":3.70},
    {"grade_label":"B", "min_pct":60,"max_pct":69.99,"gpa_point":3.30},
    {"grade_label":"C", "min_pct":50,"max_pct":59.99,"gpa_point":3.00},
    {"grade_label":"D", "min_pct":40,"max_pct":49.99,"gpa_point":2.50},
    {"grade_label":"E", "min_pct":33,"max_pct":39.99,"gpa_point":2.00},
    {"grade_label":"F", "min_pct":0, "max_pct":32.99,"gpa_point":0.00,"is_pass":false}]'::jsonb
) as fbise \gset
select public.activate_grading_scheme(:'fbise') as _act_scheme \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.create_student(:'campus_a', 'Ayesha Noor', '2015-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_a', 'Bilal Ahmed', '2015-02-01'::date, 'male')   as st_bilal \gset
select public.create_student(:'campus_a', 'Chandni Rao', '2015-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_a', 'Danish Ali',  '2015-04-01'::date, 'male')   as st_danish \gset

select public.enrol_student(:'sec_a', :'st_ayesha')  as enr_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal')   as enr_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as enr_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish')  as enr_danish \gset

-- FR-G14 clips the attendance window to the enrolment's own joined_on, so the
-- cohort has to have joined before the months being summarised below.
reset role;
update public.enrolment set joined_on = date '2026-04-01'
 where id in (:'enr_ayesha', :'enr_bilal', :'enr_chandni', :'enr_danish');
set local role authenticated;

select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550071') as g_ayesha \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g_ayesha'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@cardco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'parent_uid', :'tenant_id', 'parent', 'Ayesha Mother');
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g_ayesha'::uuid;
set local role authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- Nothing prints before the term is signed off
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$select public.fn_assert_report_card_printable(%L, %L)$$, :'enr_ayesha', :'term_f'),
  '23514',
  'term result is provisional — a paper is still being marked',
  'before any paper is signed off the term is provisional, and the card refuses in FR-J03''s own words'
);

-- Danish is debarred from English, which has to be recorded before the paper
-- is signed off — FR-I11 locks candidate exam status behind approved marks.
-- He is therefore never ranked (FR-J05 excludes a withheld candidate under
-- either policy), which is why the cohort below is three rather than four.
select public.set_exam_attendance(:'es_eng', :'enr_danish', 'debarred', 'disciplinary') as _deb \gset

-- Ayesha: 160 + 150 + 152 + 150 = 612 of 800 = 76.50%, which is grade A.
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_eng', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 180),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 170)
))) as _m1 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_urd', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 150),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 175),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 165),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 100)
))) as _m2 \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 152),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 178),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 168),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 100)
))) as _m3 \gset

select public.fn_approve_marks(:'es_eng', :'sec_a') as _a1 \gset
select public.fn_approve_marks(:'es_urd', :'sec_a') as _a2 \gset
select public.fn_approve_marks(:'es_mth', :'sec_a') as _a3 \gset

select matches(
  app.fn_report_card_block_reason(:'enr_ayesha'::uuid, :'term_f'::uuid),
  '^term result is provisional',
  'three papers of four signed off is still not a term, and the screen says so before the button is pressed'
);

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_sci', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 150),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 177),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 167),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 100)
))) as _m4 \gset
select public.fn_approve_marks(:'es_sci', :'sec_a') as _a4 \gset

select lives_ok(
  format($$select public.fn_assert_report_card_printable(%L, %L)$$, :'enr_ayesha', :'term_f'),
  'the last paper completes the term and the card becomes printable'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: what is on the card
-- ═══════════════════════════════════════════════════════════════════════

-- FR-G14's summary is the attendance feed. 180 working days, 168 present.
reset role;
insert into public.attendance_month_summary (
  tenant_id, campus_id, session_id, enrolment_id, year, month,
  working_days, present_days, absent_days, late_count, half_day_count, leave_days, attendance_pct, computed_at
) values
  (:'tenant_id', :'campus_a', :'session_a', :'enr_ayesha', 2026, 4, 90, 84, 6, 0, 0, 0, 93.33, now()),
  (:'tenant_id', :'campus_a', :'session_a', :'enr_ayesha', 2026, 5, 90, 84, 6, 0, 0, 0, 93.33, now());
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.begin_report_card(:'enr_ayesha'::uuid, :'term_f'::uuid, 'A steady term. Reads widely.') as card1 \gset
select (:'card1'::jsonb ->> 'report_card_id') as card1_id \gset
select (:'card1'::jsonb -> 'payload_snapshot') as snap1 \gset

select is(
  jsonb_array_length(:'snap1'::jsonb -> 'subjects'),
  4,
  'AC1: every subject the candidate sat is a row on the card'
);
select is(
  (:'snap1'::jsonb -> 'aggregate' ->> 'obtained')::numeric,
  612::numeric,
  'AC1: 160 + 150 + 152 + 150 aggregates to 612'
);
select is(
  (:'snap1'::jsonb -> 'aggregate' ->> 'max_marks')::int,
  800,
  'AC1: out of 800'
);
select is(
  (:'snap1'::jsonb -> 'aggregate' ->> 'pct')::numeric,
  76.50::numeric,
  'AC1: at 76.50%, rounded once off the two stored sums'
);
select is(
  :'snap1'::jsonb -> 'aggregate' ->> 'grade_label',
  'A',
  'AC1: grade A, from the scale FROZEN onto the term results rather than re-resolved'
);
select is(
  :'snap1'::jsonb -> 'grading_scheme' ->> 'name',
  'FBISE 2025',
  'and the card names the scale it was graded on, so a reprint in 2030 is answerable'
);
select is(
  (:'snap1'::jsonb -> 'position' ->> 'rank_in_section')::int,
  3,
  'AC1: the position comes from FR-J05''s stored row — 612 is third behind 710 and 670'
);
select is(
  (:'snap1'::jsonb -> 'position' ->> 'ranked_out_of')::int,
  3,
  'AC1: out of the number of RANKED candidates — three, not the section strength of four'
);
select is(
  (:'snap1'::jsonb -> 'attendance' ->> 'present_days')::numeric,
  168::numeric,
  'AC1: 168 days present, summed from FR-G14''s monthly rows rather than recounted'
);
select is(
  (:'snap1'::jsonb -> 'attendance' ->> 'working_days')::int,
  180,
  'AC1: of 180 working days'
);
select is(
  (:'snap1'::jsonb -> 'attendance' ->> 'pct')::numeric,
  93.33::numeric,
  'AC1: 93.3%'
);
select is(
  :'snap1'::jsonb -> 'attendance' ->> 'from_date',
  '2026-04-01',
  'AC1/Notes: and the date range the summary actually covers starts where the first summarised month does'
);
select is(
  :'snap1'::jsonb -> 'attendance' ->> 'to_date',
  '2026-05-31',
  'and ends where the last one does — a month nobody has computed is OUTSIDE the range, not silently inside the percentage'
);
select is(
  :'snap1'::jsonb ->> 'remark',
  'A steady term. Reads widely.',
  'the class teacher''s remark is frozen onto the card'
);
select is(
  :'snap1'::jsonb -> 'student' ->> 'gr_number',
  (select gr_number from public.student where id = :'st_ayesha'),
  'with the GR number the requirement names'
);

-- AC2: branding, resolved once from the campus, with nothing to configure.
select ok(
  :'snap1'::jsonb ? 'branding',
  'AC2: the branding paths are resolved into the snapshot rather than looked up at print time'
);
select is(
  :'snap1'::jsonb -> 'branding' ->> 'logo_storage_path',
  null,
  'AC2: and a campus that has uploaded nothing resolves to null rather than to a broken image'
);

reset role;
insert into public.branding_asset (tenant_id, campus_id, asset_type, storage_path,
                                  width_px, height_px, bytes, version, is_current, uploaded_by)
values (:'tenant_id', :'campus_a', 'logo', 'logo/crest.png', 600, 600, 40000, 1, true, :'owner_uid'),
       (:'tenant_id', :'campus_a', 'signature', 'sig/principal.png', 900, 300, 30000, 1, true, :'owner_uid');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  app.fn_build_report_card_payload(:'enr_bilal'::uuid, :'term_f'::uuid, null) -> 'branding' ->> 'logo_storage_path',
  'logo/crest.png',
  'AC2: once the campus uploads a logo every card draws it, with no per-report configuration'
);
select is(
  app.fn_build_report_card_payload(:'enr_bilal'::uuid, :'term_f'::uuid, null) -> 'branding' ->> 'signature_storage_path',
  'sig/principal.png',
  'AC2: and the principal''s signature likewise'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: a correction is a new revision
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (:'card1'::jsonb ->> 'revision_no')::int,
  1,
  'the first card is revision 1'
);
select is(
  (select supersedes_revision from public.report_card where id = :'card1_id'),
  null,
  'and supersedes nothing'
);

select public.attach_report_card_pdf(:'card1_id'::uuid, repeat('a', 64));
select is(
  (select status::text from public.report_card where id = :'card1_id'),
  'issued',
  'sealing the digest is what issues it'
);
-- ═══════════════════════════════════════════════════════════════════════════
-- FR-G15: the attendance on the card is a snapshot taken when it was issued
-- ═══════════════════════════════════════════════════════════════════════════

reset role;
select (select payload_snapshot -> 'attendance' ->> 'pct' from public.report_card where id = :'card1_id') as snap_pct \gset
update public.attendance_month_summary set present_days = 60, attendance_pct = 66.67 where enrolment_id = :'enr_ayesha' and month = 5;
select is(
  (select payload_snapshot -> 'attendance' ->> 'pct' from public.report_card where id = :'card1_id'),
  :'snap_pct',
  'G15 AC1: a later attendance correction does not change the figure on the issued card (a reprint shows what was published)'
);
select is((app.fn_report_card_attendance(:'enr_ayesha'::uuid, :'session_a'::uuid) ->> 'pct')::numeric, 80.00::numeric, 'G15 AC1: while the live view shows the corrected figure');

insert into public.attendance_month_summary (tenant_id, campus_id, session_id, enrolment_id, year, month, working_days, present_days, absent_days, late_count, half_day_count, leave_days, attendance_pct, computed_at)
values (:'tenant_id', :'campus_a', :'session_a', :'enr_bilal', 2026, 4, 20, 18, 2, 0, 0, 0, 90.00, now()),
       (:'tenant_id', :'campus_a', :'session_a', :'enr_bilal', 2026, 5, 25, 24, 1, 0, 0, 0, 96.00, now());
select is((app.fn_report_card_attendance(:'enr_bilal'::uuid, :'session_a'::uuid) ->> 'pct')::numeric, 93.33::numeric, 'G15 AC3: 42 of 45 days is 93.33%, not the 93.00% an average of 90% and 96% would give');
select is((app.fn_report_card_attendance(:'enr_bilal'::uuid, :'session_a'::uuid) ->> 'working_days')::int, 45, 'G15 AC3: working_days is the sum across the range');
select is((app.fn_report_card_attendance(:'enr_chandni'::uuid, :'session_a'::uuid) ->> 'pct'), null, 'G15 AC2: nothing summarised for the range -> pct is NULL, never 0');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text, true);
select public.begin_report_card(:'enr_bilal'::uuid, :'term_f'::uuid, null) as bcard \gset
select (:'bcard'::jsonb ->> 'report_card_id') as bcard_id \gset
select public.attach_report_card_pdf(:'bcard_id'::uuid, repeat('c', 64));
reset role;
select is((select payload_snapshot -> 'attendance' ->> 'pct' from public.report_card where id = :'bcard_id'), '93.33', 'G15: Bilal''s issued card froze the summed figure');

-- ═══════════════════════════════════════════════════════════════════════════
-- FR-J15: a correction stales the whole section; parents keep a banner; re-issue supersedes
-- ═══════════════════════════════════════════════════════════════════════════

-- Ayesha's mother is the fixture's activated guardian; give Bilal one too.
select :'parent_uid' as par_a \gset
select gen_random_uuid() as par_b \gset
insert into auth.users (id, phone, aud, role, encrypted_password) values (:'par_b', '923001230002', 'authenticated', 'authenticated', 'x');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text, true);
select public.fn_find_or_create_guardian(p_name_en => 'Bilal Father', p_phone_e164 => '+923001230002') as g_b \gset
select public.link_guardian(:'st_bilal'::uuid, :'g_b'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'par_b' where id = :'g_b'::uuid;

select is((select count(*)::int from public.report_card where status = 'issued' and section_id = :'sec_a'), 2, 'J15: two cards (Ayesha, Bilal) are issued before the correction');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text, true);
select public.request_mark_unlock(:'es_mth', :'sec_a', 'Q7 total mis-added on Chandni''s script') as unlock_req \gset
reset role;
select id as chandni_mark from public.mark_entry where exam_subject_id = :'es_mth' and enrolment_id = :'enr_chandni' limit 1 \gset

-- only Chandni's mark changes ...
insert into public.mark_entry_audit (tenant_id, campus_id, mark_unlock_request_id, mark_entry_id, exam_subject_id, section_id, enrolment_id, component_code, action, old_marks, new_marks, actor_user_id)
values (:'tenant_id', :'campus_a', :'unlock_req', :'chandni_mark', :'es_mth', :'sec_a', :'enr_chandni', 'theory', 'update', 150, 178, :'ec_uid');

select is((select count(*)::int from public.report_card where status = 'stale' and section_id = :'sec_a'), 2, 'J15 AC1/AC2: ... yet BOTH issued cards in the section go stale, including the uncorrected candidates (the section re-ranks)');
select ok((select bool_and(stale_reason like 'Marks corrected: Maths%') from public.report_card where status = 'stale'), 'J15 AC1: each stale card names the changed dependency');
select ok((select bool_and(stale_at is not null) from public.report_card where status = 'stale'), 'and records when');

-- a no-op audit row (same value) must not stale anything
update public.report_card set status = 'issued', stale_at = null, stale_reason = null where id = :'bcard_id';
insert into public.mark_entry_audit (tenant_id, campus_id, mark_unlock_request_id, mark_entry_id, exam_subject_id, section_id, enrolment_id, component_code, action, old_marks, new_marks, actor_user_id)
values (:'tenant_id', :'campus_a', :'unlock_req', :'chandni_mark', :'es_mth', :'sec_a', :'enr_chandni', 'theory', 'update', 178, 178, :'ec_uid');
select is((select status::text from public.report_card where id = :'bcard_id'), 'issued', 'an audit row that changes nothing does not stale a card');
insert into public.mark_entry_audit (tenant_id, campus_id, mark_unlock_request_id, mark_entry_id, exam_subject_id, section_id, enrolment_id, component_code, action, old_marks, new_marks, actor_user_id)
values (:'tenant_id', :'campus_a', :'unlock_req', :'chandni_mark', :'es_mth', :'sec_a', :'enr_chandni', 'theory', 'update', 178, 170, :'ec_uid');
select is((select count(*)::int from public.report_card where status = 'stale'), 2, 'and a real change stales both again');

-- ── parent view ───────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'par_a', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*)::int from public.report_card), 1, 'J15 AC4: a parent still sees their child''s previous card — it does not disappear');
select is((select under_review from public.fn_portal_report_cards(:'enr_ayesha'::uuid)), true, 'J15 AC4: flagged "result under review"');
select is((select revised_on from public.fn_portal_report_cards(:'enr_ayesha'::uuid)), null, 'and no revised-on notice yet (still revision 1)');
reset role;

-- ── re-issue: revision 2 issued, revision 1 superseded but kept ───────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text, true);
select public.begin_report_card(:'enr_ayesha'::uuid, :'term_f'::uuid, null) as rev2 \gset
select (:'rev2'::jsonb ->> 'report_card_id') as rev2_id \gset
select is((:'rev2'::jsonb ->> 'revision_no')::int, 2, 'J15 AC3: the Exam Controller re-issues as revision 2');
select is((select status::text from public.report_card where id = :'card1_id'), 'stale', 'revision 1 stays stale until revision 2 actually exists as a document');
select public.attach_report_card_pdf(:'rev2_id'::uuid, repeat('d', 64));
select is((select status::text from public.report_card where id = :'card1_id'), 'superseded', 'J15 AC3: revision 1 is superseded ...');
select is((select count(*)::int from public.report_card where enrolment_id = :'enr_ayesha'), 2, '... and kept for audit (staff still see both revisions)');
select is((select status::text from public.report_card where id = :'rev2_id'), 'issued', 'revision 2 is current');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'par_a', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*)::int from public.report_card), 1, 'the parent sees exactly one card — revision 2');
select is((select revision_no from public.fn_portal_report_cards(:'enr_ayesha'::uuid)), 2, 'J15 AC3: the portal serves revision 2');
select is((select under_review from public.fn_portal_report_cards(:'enr_ayesha'::uuid)), false, 'with the review banner gone');
select ok((select revised_on is not null from public.fn_portal_report_cards(:'enr_ayesha'::uuid)), 'J15 AC3: and a "revised on <date>" notice');
select set_config('request.jwt.claims', json_build_object('sub', :'par_b', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select under_review from public.fn_portal_report_cards(:'enr_bilal'::uuid)), true, 'the sibling section''s uncorrected card is still under review until re-issued');
select is((select count(*)::int from public.fn_portal_report_cards(:'enr_ayesha'::uuid)), 0, 'and one family cannot ask about another family''s child');
reset role;

select * from finish();
rollback;
