-- pgTAP tests for FR-J06: subject-wise student analytics.
--
--   AC1  a student scoring 62%, 55% and 71% in Chemistry across three terms
--        gets three points beside section averages of 58%, 60% and 64%.
--   AC2  a section with fewer than 5 ranked candidates has its average
--        suppressed with "too few students to compare".
--   AC3  a parent sees only their own child's series plus the aggregate
--        averages; no other student is identifiable.
--   AC4  a term with no locked marks is omitted rather than plotted as zero.
--
-- Plus: the averages are materialised (a mark changed after the refresh does
-- not move them until the next refresh), a lock refreshes them by itself, a
-- withheld candidate does not count, and other schools see nothing.
begin;
select plan(26);

select public.provision_tenant('test-trend-co', 'Trend Co', 'owner@trendco.test');
select id as tenant_id from public.tenant where slug = 'test-trend-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-trend-rival', 'Trend Rival', 'owner@trendrival.test');
select id as rival_id from public.tenant where slug = 'test-trend-rival' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as parent2_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@trendco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'ec_uid', 'e@trendco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent_uid', 'p@trendco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent2_uid', 'p2@trendco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@trendrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal'),
  (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_subject('CHM', 'Chemistry', 'کیمیا') as s_chm \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_chm', 5::smallint) as cs_chm \gset
select public.create_section(:'campus_id', :'session_id', :'class9', 'A', 40) as sec_a \gset
select public.create_section(:'campus_id', :'session_id', :'class9', 'B', 40) as sec_b \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 30.00) as term_1 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T2', 'Mid Term', 2::smallint, 30.00) as term_2 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T3', 'Final Term', 3::smallint, 40.00) as term_3 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T4', 'Pre-Board', 4::smallint, 0.00, false) as term_4 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _act \gset
select public.upsert_exam_subject(:'term_1', :'cs_chm', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_1 \gset
select public.upsert_exam_subject(:'term_2', :'cs_chm', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_2 \gset
select public.upsert_exam_subject(:'term_3', :'cs_chm', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_3 \gset
select public.upsert_exam_subject(:'term_4', :'cs_chm', '[{"component":"theory","max_marks":100,"pass_marks":0}]'::jsonb) as es_4 \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
select public.activate_grading_scheme(public.save_grading_scheme('FBISE'::public.board, 'FBISE 2025', date '2000-01-01',
  '[{"grade_label":"A1","min_pct":80,"max_pct":100,"gpa_point":4.00},{"grade_label":"B","min_pct":50,"max_pct":79.99,"gpa_point":3.00},
    {"grade_label":"F","min_pct":0,"max_pct":49.99,"gpa_point":0.00,"is_pass":false}]'::jsonb)) as _scheme \gset

-- Section A: six candidates. Section B: three (below the 5 threshold).
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_student(:'campus_id', 'Ayesha Noor', '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_id', 'Bilal Ahmed', '2011-02-01'::date, 'male') as st_bilal \gset
select public.create_student(:'campus_id', 'Chandni Rao', '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_id', 'Danish Ali', '2011-04-01'::date, 'male') as st_danish \gset
select public.create_student(:'campus_id', 'Emaan Zafar', '2011-05-01'::date, 'female') as st_emaan \gset
select public.create_student(:'campus_id', 'Farhan Qazi', '2011-06-01'::date, 'male') as st_farhan \gset
select public.create_student(:'campus_id', 'Gul Naz', '2011-07-01'::date, 'female') as st_gul \gset
select public.create_student(:'campus_id', 'Hamza Raza', '2011-08-01'::date, 'male') as st_hamza \gset
select public.create_student(:'campus_id', 'Iqra Sheikh', '2011-09-01'::date, 'female') as st_iqra \gset
select public.enrol_student(:'sec_a', :'st_ayesha') as e_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal') as e_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as e_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish') as e_danish \gset
select public.enrol_student(:'sec_a', :'st_emaan') as e_emaan \gset
select public.enrol_student(:'sec_a', :'st_farhan') as e_farhan \gset
select public.enrol_student(:'sec_b', :'st_gul') as e_gul \gset
select public.enrol_student(:'sec_b', :'st_hamza') as e_hamza \gset
select public.enrol_student(:'sec_b', :'st_iqra') as e_iqra \gset

select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550041') as g_ayesha \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g_ayesha'::uuid, 'mother'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Bilal Father', p_phone_e164 => '+923005550042') as g_bilal \gset
select public.link_guardian(:'st_bilal'::uuid, :'g_bilal'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g_ayesha'::uuid;
update public.guardian set auth_user_id = :'parent2_uid'::uuid where id = :'g_bilal'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);

-- Marks. Section A: Ayesha 62/55/71 with the rest chosen so the averages are
-- exactly 58 / 60 / 64. Section B: three candidates.
create temp table _m (term text, enr uuid, marks numeric);
insert into _m values
  ('1', :'e_ayesha', 62), ('1', :'e_bilal', 55), ('1', :'e_chandni', 57), ('1', :'e_danish', 58), ('1', :'e_emaan', 58), ('1', :'e_farhan', 58),
  ('2', :'e_ayesha', 55), ('2', :'e_bilal', 61), ('2', :'e_chandni', 61), ('2', :'e_danish', 61), ('2', :'e_emaan', 61), ('2', :'e_farhan', 61),
  ('3', :'e_ayesha', 71), ('3', :'e_bilal', 62), ('3', :'e_chandni', 63), ('3', :'e_danish', 63), ('3', :'e_emaan', 63), ('3', :'e_farhan', 62),
  ('1', :'e_gul', 90), ('1', :'e_hamza', 80), ('1', :'e_iqra', 70),
  ('2', :'e_gul', 90), ('2', :'e_hamza', 80), ('2', :'e_iqra', 70),
  ('3', :'e_gul', 90), ('3', :'e_hamza', 80), ('3', :'e_iqra', 70);
-- Pre-Board: marks typed but the paper is never signed off.
insert into _m values ('4', :'e_ayesha', 12), ('4', :'e_bilal', 14);

create function pg_temp.enter(p_es uuid, p_term text, p_enrs uuid[]) returns void language plpgsql as $f$
begin
  perform public.fn_upsert_marks(jsonb_build_object('exam_subject_id', p_es, 'marks',
    (select jsonb_agg(jsonb_build_object('enrolment_id', m.enr, 'component', 'theory', 'marks_obtained', m.marks))
       from _m m where m.term = p_term and m.enr = any (p_enrs))));
end $f$;

select pg_temp.enter(:'es_1', '1', array[:'e_ayesha', :'e_bilal', :'e_chandni', :'e_danish', :'e_emaan', :'e_farhan']::uuid[]);
select pg_temp.enter(:'es_1', '1', array[:'e_gul', :'e_hamza', :'e_iqra']::uuid[]);
select pg_temp.enter(:'es_2', '2', array[:'e_ayesha', :'e_bilal', :'e_chandni', :'e_danish', :'e_emaan', :'e_farhan']::uuid[]);
select pg_temp.enter(:'es_2', '2', array[:'e_gul', :'e_hamza', :'e_iqra']::uuid[]);
select pg_temp.enter(:'es_3', '3', array[:'e_ayesha', :'e_bilal', :'e_chandni', :'e_danish', :'e_emaan', :'e_farhan']::uuid[]);
select pg_temp.enter(:'es_3', '3', array[:'e_gul', :'e_hamza', :'e_iqra']::uuid[]);
select pg_temp.enter(:'es_4', '4', array[:'e_ayesha', :'e_bilal']::uuid[]);

-- Term 1 is signed off section by section; the first lock must not yet
-- produce results for section A's neighbours, the last one must.
select public.fn_approve_marks(:'es_1', :'sec_a') as _l1a \gset
select public.fn_approve_marks(:'es_1', :'sec_b') as _l1b \gset

select has_trigger('public', 'mark_lock', 'trg_refresh_subject_averages', 'the averages are refreshed on mark_lock insert');
select has_index('app', 'mv_subject_term_average', 'uq_mv_subject_avg', array['exam_term_id', 'section_id', 'subject_id'], 'uq_mv_subject_avg exists for CONCURRENTLY refreshes');

-- ── AC1 (term 1 materialised by the lock itself) ──────────────────────────
select is((select avg_pct from app.mv_subject_term_average where exam_term_id = :'term_1' and section_id = :'sec_a'), 58.00::numeric,
          'locking the paper refreshed the average by itself: Term 1 section average is 58.00');
select is((select n from app.mv_subject_term_average where exam_term_id = :'term_1' and section_id = :'sec_a'), 6, 'over six ranked candidates');

select public.fn_approve_marks(:'es_2', :'sec_a') as _l2a \gset
select public.fn_approve_marks(:'es_2', :'sec_b') as _l2b \gset
select public.fn_approve_marks(:'es_3', :'sec_a') as _l3a \gset
select public.fn_approve_marks(:'es_3', :'sec_b') as _l3b \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);

select is((select array_agg(pct order by term_sequence) from public.v_student_subject_trend where enrolment_id = :'e_ayesha' and subject_id = :'s_chm'),
          array[62.00, 55.00, 71.00]::numeric[], 'AC1: the three Chemistry points are 62, 55 and 71');
select is((select array_agg(section_avg_pct order by term_sequence) from public.v_student_subject_trend where enrolment_id = :'e_ayesha' and subject_id = :'s_chm'),
          array[58.00, 60.00, 64.00]::numeric[], 'AC1: beside section averages of 58, 60 and 64 on the same rows');
select is((select array_agg(term_name order by term_sequence) from public.v_student_subject_trend where enrolment_id = :'e_ayesha'),
          array['First Term', 'Mid Term', 'Final Term'], 'terms come back named and in order for the x axis');
select is((select bool_or(comparison_suppressed) from public.v_student_subject_trend where enrolment_id = :'e_ayesha'), false, 'a six-candidate section is compared');

-- ── AC2 ───────────────────────────────────────────────────────────────────
select is((select count(*)::int from public.v_student_subject_trend where enrolment_id = :'e_gul' and section_avg_pct is null), 3,
          'AC2: a section of three has its average suppressed in every term');
select is((select distinct comparison_note from public.v_student_subject_trend where enrolment_id = :'e_gul'), 'too few students to compare',
          'AC2: with the explanation "too few students to compare"');
select is((select count(*)::int from public.v_student_subject_trend where enrolment_id = :'e_gul' and pct is not null), 3, 'and the child''s own points are still plotted');
select is((select count(*)::int from public.v_section_subject_average where section_id = :'sec_b' and avg_pct is not null), 0, 'the staff section view suppresses it too');
select is((select avg_pct from public.v_section_subject_average where section_id = :'sec_a' and term_sequence = 3), 64.00::numeric, 'the staff section view shows the six-candidate average');

-- ── AC4 ───────────────────────────────────────────────────────────────────
select is((select count(*)::int from public.v_student_subject_trend where enrolment_id = :'e_ayesha' and exam_term_id = :'term_4'), 0,
          'AC4: the Pre-Board paper was never signed off, so that term is omitted');
select is((select count(*)::int from public.v_student_subject_trend where enrolment_id = :'e_ayesha' and pct = 0), 0, 'AC4: and nothing is plotted as zero');

-- ── materialised, not computed on read ────────────────────────────────────
reset role;
update public.subject_result set pct = 100 where enrolment_id = :'e_bilal' and exam_term_id = :'term_1';
select is((select avg_pct from app.mv_subject_term_average where exam_term_id = :'term_1' and section_id = :'sec_a'), 58.00::numeric,
          'a result changed after the refresh does not move the average until the next refresh (never computed on read)');
select public.fn_refresh_subject_averages(:'term_1'::uuid) as _rf \gset
select is((select avg_pct from app.mv_subject_term_average where exam_term_id = :'term_1' and section_id = :'sec_a'), 65.50::numeric, 'fn_refresh_subject_averages brings it up to date');
update public.subject_result set pct = 55 where enrolment_id = :'e_bilal' and exam_term_id = :'term_1';
select public.fn_refresh_subject_averages(null) as _rf2 \gset

-- A withheld candidate is not "ranked": the average excludes them.
insert into public.result_withhold (tenant_id, campus_id, exam_term_id, enrolment_id, reason, cutoff_date)
values (:'tenant_id', :'campus_id', :'term_1', :'e_farhan', 'discipline', current_date);
select public.fn_refresh_subject_averages(:'term_1'::uuid) as _rf3 \gset
select is((select n from app.mv_subject_term_average where exam_term_id = :'term_1' and section_id = :'sec_a'), 5, 'a withheld result is left out of the average');
delete from public.result_withhold where enrolment_id = :'e_farhan';
select public.fn_refresh_subject_averages(:'term_1'::uuid) as _rf4 \gset

-- ── AC3: the parent ───────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent_uid')::text, true);
select is((select array_agg(pct order by term_sequence) from public.v_student_subject_trend), array[62.00, 55.00, 71.00]::numeric[],
          'AC3: the parent sees exactly their own child''s series');
select is((select count(distinct student_id)::int from public.v_student_subject_trend), 1, 'AC3: and no other student appears in it');
select is((select array_agg(section_avg_pct order by term_sequence) from public.v_student_subject_trend), array[58.00, 60.00, 64.00]::numeric[],
          'AC3: the aggregate section averages are visible to the parent');
select is((select count(*)::int from public.v_student_subject_trend where enrolment_id = :'e_bilal'), 0, 'AC3: another child in the same section cannot be read');
select is((select count(*)::int from public.v_section_subject_average), 0, 'the staff section view is closed to parents');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent2_uid')::text, true);
select is((select array_agg(pct order by term_sequence) from public.v_student_subject_trend), array[55.00, 61.00, 62.00]::numeric[], 'a second parent sees only their own child');
select throws_ok(format($$select public.fn_refresh_subject_averages(%L)$$, :'term_1'), '42501', null, 'a parent cannot trigger a refresh');

-- ── other school ──────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select is((select count(*)::int from public.v_student_subject_trend) + (select count(*)::int from public.v_section_subject_average), 0, 'another school sees no trend or average');

select * from finish();
rollback;
