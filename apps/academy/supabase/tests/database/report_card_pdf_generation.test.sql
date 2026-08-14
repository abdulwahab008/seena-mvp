-- pgTAP tests for FR-J09: report card PDF generation.
--
--   AC1  a candidate with several subjects gets one card carrying every
--        subject row, the aggregate out of the total at its percentage and
--        grade, the position "n of m", and the attendance summary with the
--        date range it covers printed beside it.
--   AC2  the logo and the signature come from campus branding, resolved once,
--        with no per-report configuration.
--   AC3  a withheld candidate is refused with 'result_withheld' and NO row
--        and no path are reserved.
--   AC4  a regeneration after a correction increments revision_no and records
--        which revision it supersedes.
--
-- Plus the properties the acceptance criteria do not state and the module
-- depends on:
--
--   * the card refuses to print while the term is provisional and while
--     FR-I17 has marked a result stale — two different sentences, because two
--     different people have to fix them, and because a printed page cannot be
--     recalled once the number on it turns out to be wrong;
--   * a debarred candidate is refused for debarment rather than for money;
--   * the aggregate is graded on the scheme FROZEN onto the term results, not
--     on whatever is active today;
--   * the snapshot is the card: it carries the position, the attendance
--     window and the branding paths, which are the four things that would
--     otherwise drift under a revision number;
--   * a reserved revision that never becomes a document is voided, not
--     deleted, so the number cannot be reused;
--   * a parent sees the current issued revision and nothing while withheld;
--   * report cards are tenant-isolated, cannot be written directly, and the
--     table cannot be truncated.
begin;
select plan(50);

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

select public.begin_report_card(:'enr_ayesha'::uuid, :'term_f'::uuid, null) as card2 \gset
select (:'card2'::jsonb ->> 'report_card_id') as card2_id \gset

select is(
  (:'card2'::jsonb ->> 'revision_no')::int,
  2,
  'AC4: regenerating increments revision_no'
);
select is(
  (:'card2'::jsonb -> 'payload_snapshot' ->> 'supersedes_revision')::int,
  1,
  'AC4: and the snapshot carries what the footer prints — "supersedes revision 1"'
);
select is(
  :'card2'::jsonb -> 'payload_snapshot' ->> 'remark',
  'A steady term. Reads widely.',
  'a regeneration with no new remark carries the class teacher''s words forward rather than erasing them'
);
select isnt(
  :'card2'::jsonb ->> 'storage_path',
  :'card1'::jsonb ->> 'storage_path',
  'and it takes its own path — the bytes behind revision 1 are never overwritten'
);

select public.attach_report_card_pdf(:'card2_id'::uuid, repeat('b', 64));
select is(
  (select status::text from public.report_card where id = :'card1_id'),
  'superseded',
  'AC4: revision 1 becomes superseded the moment revision 2 exists as a document, not when one was requested'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: withheld, and nothing is written
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select public.post_ledger_entry(:'enr_bilal'::uuid, 'charge'::public.fee_ledger_entry_type,
                                1200000::bigint, 'debit'::public.fee_ledger_direction) as _l1 \gset
select public.set_result_withhold_threshold(:'campus_a'::uuid, 500000::bigint);
select public.fn_sync_fee_withholds(:'term_f'::uuid) as _sync \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  (select count(*)::int from public.report_card where enrolment_id = :'enr_bilal'),
  0,
  'AC3: the withheld candidate has no card to begin with'
);
select throws_ok(
  format($$select public.begin_report_card(%L, %L)$$, :'enr_bilal', :'term_f'),
  '23514',
  'result withheld — outstanding dues of PKR 12,000 as at ' || to_char(current_date, 'DD Mon YYYY') || ' exceed the PKR 5,000 threshold',
  'AC3: rendering is refused, and the sentence names the amount, the cut-off and the threshold'
);
select is(
  (select count(*)::int from public.report_card where enrolment_id = :'enr_bilal'),
  0,
  'AC3: and NO row is reserved — refusing before the revision number is what makes "no file is written" true'
);

-- The machine-readable half of AC3, so a caller does not pattern-match prose.
-- pgTAP counts a test taken inside a DO block but never prints its TAP line,
-- so the detail is captured first and asserted in the open.
create temporary table _refusal_detail (detail text);
select format($fmt$
do $body$
declare v_detail text;
begin
  begin
    perform public.begin_report_card(%L::uuid, %L::uuid);
  exception when check_violation then
    get stacked diagnostics v_detail = pg_exception_detail;
  end;
  insert into _refusal_detail values (v_detail);
end;
$body$;
$fmt$, :'enr_bilal', :'term_f') \gexec

select is(
  (select detail from _refusal_detail),
  'result_withheld',
  'AC3: the refusal carries ''result_withheld'' as its DETAIL, so a caller need not pattern-match prose'
);

-- Debarment is a different refusal at a different desk.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format($$select public.begin_report_card(%L, %L)$$, :'enr_danish', :'term_f'),
  '23514',
  'result withheld — the candidate is debarred in this term',
  'a debarred candidate is refused for debarment, not for money'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Stale data never reaches paper
-- ═══════════════════════════════════════════════════════════════════════

select is(
  app.fn_report_card_block_reason(:'enr_chandni'::uuid, :'term_f'::uuid),
  null,
  'a clean candidate has no block reason, so the screen and the button agree'
);

-- FR-I17's stamp, reached the only way the schema allows: mark_lock is
-- append-only, so a result goes stale because a break-glass window was opened
-- on one of its papers and a mark was corrected inside it.
select public.request_mark_unlock(:'es_mth', :'sec_a', 'Q7 total mis-added on Chandni''s script') as unlock_req \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'unlock_req', 60) as _bg \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 178)
))) as _fix \gset

select throws_ok(
  format($$select public.begin_report_card(%L, %L)$$, :'enr_chandni', :'term_f'),
  '23514',
  'term result is stale — a mark changed after it was computed',
  'a card refuses to print a number the database already knows is wrong'
);
select matches(
  app.fn_report_card_block_reason(:'enr_chandni'::uuid, :'term_f'::uuid),
  '^term result is stale',
  'and the screen says the same thing before the button is pressed'
);
select matches(
  app.fn_report_card_block_reason(:'enr_ayesha'::uuid, :'term_f'::uuid),
  '^term result is stale',
  'FR-J05 AC4: the classmate whose marks nobody touched is stale too, because their position moved'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The register: voided, not deleted; parent-facing; isolated
-- ═══════════════════════════════════════════════════════════════════════

-- Only recomputing the term result clears it, exactly as FR-J03 and FR-J05
-- both insist: closing the window is not enough on its own.
select public.fn_relock_expired_unlocks(clock_timestamp() + interval '5 hours') as _relock \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.fn_compute_subject_result(:'term_f', :'sec_a') as _recompute \gset
select is(
  app.fn_report_card_block_reason(:'enr_chandni'::uuid, :'term_f'::uuid),
  null,
  'and once the term results are recomputed the card is printable again'
);

select public.begin_report_card(:'enr_chandni'::uuid, :'term_f'::uuid, 'Good progress.') as card3 \gset
select (:'card3'::jsonb ->> 'report_card_id') as card3_id \gset
select public.void_report_card(:'card3_id'::uuid, 'RENDERER_UNAVAILABLE');
select is(
  (select status::text from public.report_card where id = :'card3_id'),
  'void',
  'a reserved revision whose bytes never appeared is voided, not deleted'
);
select is(
  (select void_reason from public.report_card where id = :'card3_id'),
  'RENDERER_UNAVAILABLE',
  'with the reason on the row'
);
select public.begin_report_card(:'enr_chandni'::uuid, :'term_f'::uuid, null) as card4 \gset
select is(
  (:'card4'::jsonb ->> 'revision_no')::int,
  2,
  'and a voided revision still consumes its number — FR-T02''s rule, so nothing is ever reissued'
);
select is(
  (:'card4'::jsonb -> 'payload_snapshot' ->> 'supersedes_revision'),
  null,
  'but it supersedes nothing, because revision 1 never became a document — a footer saying otherwise would be a lie'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(*)::int from public.report_card),
  1,
  'a parent sees exactly one card — their own child''s, and only the issued revision'
);
select is(
  (select revision_no from public.report_card),
  2,
  'and it is the current one; a superseded revision is a register entry, not a document to hand over'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.report_card),
  0,
  'another tenant sees no report cards at all'
);
select throws_ok(
  format($$select public.fn_report_card_sheet(%L, %L)$$, :'term_f', :'sec_a'),
  '42501',
  'FORBIDDEN',
  'nor reads its print list'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
update public.report_card set checksum = repeat('0', 64) where id = :'card2_id';
select is(
  (select checksum from public.report_card where id = :'card2_id'),
  repeat('b', 64),
  'a checksum cannot be rewritten by a direct UPDATE — it is a statement about bytes already in the bucket'
);
select throws_ok(
  $$truncate public.report_card$$,
  '42501',
  null,
  'and the register cannot be truncated: the revision series would restart and reissue a number already printed'
);

select * from finish();
rollback;
