-- pgTAP tests for FR-I03: datesheet clash detection.
--
--   AC1  Class 9 Physics 09:00-11:00 and Class 9 Computer Science 10:00-12:00 the
--        same day, 12 pupils registered for both: the second save is blocked and
--        the 12 GR numbers are listed.
--   AC2  Overlapping slots with no shared candidate save; only a hall-capacity
--        note is returned.
--   AC3  Hall of 120 and 140 candidates: saved, with a non-blocking "capacity
--        short by 20" warning.
--   AC4  Friday 11:00-13:00 against a 12:00 Jummah cut-off: a warning naming the
--        Jummah conflict.
begin;
select plan(35);

select public.provision_tenant('test-datesheet-co', 'Datesheet Co', 'owner@datesheet.test');
select id as tenant_id from public.tenant where slug = 'test-datesheet-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select public.provision_tenant('test-datesheet-other', 'Other Datesheet Co', 'owner@otherdatesheet.test');
select id as other_tenant_id from public.tenant where slug = 'test-datesheet-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@datesheet.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@datesheet.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@datesheet.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@datesheet.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'parent_uid', :'tenant_id', 'parent', 'Parent');

-- Captures the message and DETAIL of a failing statement (the DETAIL carries the GR numbers).
create function pg_temp.cap(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'no error';
exception when others then
  declare v_detail text;
  begin
    get stacked diagnostics v_detail = pg_exception_detail;
    return sqlerrm || ' | ' || coalesce(v_detail, '');
  end;
end;
$$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.create_subject('CS', 'Computer Science', 'کمپیوٹر سائنس') as s_cs \gset
select public.create_subject('BIO', 'Biology', 'حیاتیات') as s_bio \gset
select public.create_subject('MTH', 'Mathematics', 'ریاضی') as s_mth \gset
select public.create_subject('SCI', 'Science', 'سائنس') as s_sci \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint, null, false, 1::smallint, 1::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_cs', 4::smallint, null, false, 2::smallint, 1::smallint) as cs_cs \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_bio', 4::smallint, null, false, 3::smallint, 1::smallint) as cs_bio \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class10', :'s_mth', 6::smallint) as cs_mth \gset
select public.upsert_class_subject(:'campus_id', :'session_id', :'class10', :'s_sci', 6::smallint) as cs_sci \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec9 \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class10'::uuid, 'A', 150) as sec10 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', :'cs_phy', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_phy \gset
select public.upsert_exam_subject(:'term1', :'cs_cs', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_cs \gset
select public.upsert_exam_subject(:'term1', :'cs_bio', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_bio \gset
select public.upsert_exam_subject(:'term1', :'cs_mth', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb) as es_mth \gset
select public.upsert_exam_subject(:'term1', :'cs_sci', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb) as es_sci \gset

reset role;
-- Class 9: 1-12 take Physics AND Computer Science, 13-16 Physics only, 17-20 CS only, 21-26 Biology only.
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'GR9-' || lpad(g::text, 3, '0'), 'Nine ' || g, date '2011-01-01', 'male' from generate_series(1, 26) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', st.id, :'class9', :'sec9', right(st.gr_number, 3)::int
  from public.student st where st.tenant_id = :'tenant_id' and st.gr_number like 'GR9-%';
insert into public.student_elective_choice (tenant_id, campus_id, student_id, session_id, class_level_id, elective_bucket, subject_id)
select :'tenant_id', :'campus_id', st.id, :'session_id', :'class9', b.bucket, b.subject
  from public.student st
  join lateral (values (1::smallint, :'s_phy'::uuid, 1, 16), (2::smallint, :'s_cs'::uuid, 1, 12), (2::smallint, :'s_cs'::uuid, 17, 20), (3::smallint, :'s_bio'::uuid, 21, 26)) b(bucket, subject, lo, hi)
    on right(st.gr_number, 3)::int between b.lo and b.hi
 where st.tenant_id = :'tenant_id' and st.gr_number like 'GR9-%';
-- Class 10: 140 pupils, compulsory Mathematics and Science.
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'GR10-' || lpad(g::text, 3, '0'), 'Ten ' || g, date '2010-01-01', 'female' from generate_series(1, 140) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', st.id, :'class10', :'sec10', right(st.gr_number, 3)::int
  from public.student st where st.tenant_id = :'tenant_id' and st.gr_number like 'GR10-%';

-- ── candidate resolution goes through enrolment and electives ─────────────
select is((select count(*) from app.fn_exam_subject_candidates(:'es_phy'::uuid)), 16::bigint, 'Physics candidates are the pupils who chose Physics, not all of Class 9');
select is((select count(*) from app.fn_exam_subject_candidates(:'es_mth'::uuid)), 140::bigint, 'a compulsory subject takes every active enrolment of the class');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_exam_hall(:'campus_id'::uuid, 'H1', 'Main Hall', 10, 12) as hall1 \gset
select public.save_exam_hall(:'campus_id'::uuid, 'H2', 'Hall Two', 5, 5) as hall2 \gset
select public.save_exam_hall(:'campus_id'::uuid, 'H3', 'Hall Three', 10, 12) as hall3 \gset
select is((select capacity from public.exam_hall where id = :'hall1'::uuid), 120, 'a 10 x 12 hall holds 120');
select public.create_datesheet(:'campus_id'::uuid, :'term1'::uuid, 'First Term datesheet') as ds \gset

-- ── AC1: the clash blocks the save and names the 12 GR numbers ────────────
select public.save_datesheet_slot(:'ds'::uuid, :'es_phy'::uuid, '2026-09-08'::date, '09:00'::time, '11:00'::time, :'hall1'::uuid) ->> 'slot_id' as slot_phy \gset
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 1::bigint, 'the first slot saves');
select pg_temp.cap(format($$ select public.save_datesheet_slot(%L, %L, '2026-09-08', '10:00', '12:00', %L) $$, :'ds', :'es_cs', :'hall2')) as clash_msg \gset
select ok(:'clash_msg'::text like 'DATESHEET_CLASH%', 'AC1: the overlapping slot with shared candidates is refused');
select ok(:'clash_msg'::text like '%12 candidates sit both papers%', 'AC1: the refusal counts the 12 affected candidates');
select is((select count(*) from regexp_matches(:'clash_msg', 'GR9-0(0[1-9]|1[0-2])', 'g')), 12::bigint, 'AC1: all 12 GR numbers (GR9-001..GR9-012) are listed');
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 1::bigint, 'AC1: nothing was stored for the blocked slot');

-- ── AC2: no shared candidate, overlapping windows -> saves, hall note only ─
select public.save_datesheet_slot(:'ds'::uuid, :'es_bio'::uuid, '2026-09-08'::date, '10:00'::time, '12:00'::time, :'hall2'::uuid) as bio_result \gset
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 2::bigint, 'AC2: overlapping slots with zero shared candidates save');
select is(jsonb_array_length((:'bio_result'::jsonb) -> 'warnings'), 1, 'AC2: exactly one message comes back');
select is((:'bio_result'::jsonb) -> 'warnings' -> 0 ->> 'code', 'hall_capacity', 'AC2: and it is the hall-capacity note');
select is((:'bio_result'::jsonb) -> 'warnings' -> 0 ->> 'severity', 'note', 'AC2: not a warning');

-- ── AC3: hall of 120, 140 candidates -> non-blocking warning ──────────────
select public.save_datesheet_slot(:'ds'::uuid, :'es_mth'::uuid, '2026-09-09'::date, '09:00'::time, '11:00'::time, :'hall1'::uuid) as mth_result \gset
select is((:'mth_result'::jsonb) -> 'warnings' -> 0 ->> 'code', 'capacity_short', 'AC3: the slot saves with a capacity warning');
select is((:'mth_result'::jsonb) -> 'warnings' -> 0 ->> 'message', 'capacity short by 20', 'AC3: "capacity short by 20"');
select is((:'mth_result'::jsonb) -> 'warnings' -> 0 ->> 'severity', 'warning', 'AC3: it is a warning, not a block');
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 3::bigint, 'AC3: the over-capacity slot is stored');

-- ── AC4: Friday 11:00-13:00 against the 12:00 Jummah cut-off ──────────────
select public.save_datesheet_slot(:'ds'::uuid, :'es_sci'::uuid, '2026-09-11'::date, '11:00'::time, '13:00'::time, :'hall3'::uuid) as sci_result \gset
select ok((select bool_or(w ->> 'code' = 'jummah_conflict') from jsonb_array_elements((:'sci_result'::jsonb) -> 'warnings') w), 'AC4: a Jummah conflict warning is raised');
select ok((select w ->> 'message' from jsonb_array_elements((:'sci_result'::jsonb) -> 'warnings') w where w ->> 'code' = 'jummah_conflict') like 'Jummah conflict%', 'AC4: the warning names the Jummah conflict');
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 4::bigint, 'AC4: and the slot is saved');
select public.save_datesheet_slot(:'ds'::uuid, :'es_sci'::uuid, '2026-09-11'::date, '09:00'::time, '11:30'::time, :'hall3'::uuid) as sci_early \gset
select is((select count(*) from jsonb_array_elements((:'sci_early'::jsonb) -> 'warnings') w where w ->> 'code' = 'jummah_conflict'), 0::bigint, 'a Friday paper finished before the cut-off raises no Jummah warning');
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 4::bigint, 're-saving a paper moves its slot rather than adding another');

-- ── the campus cut-off is a setting ───────────────────────────────────────
select public.save_datesheet_slot(:'ds'::uuid, :'es_sci'::uuid, '2026-09-11'::date, '11:00'::time, '13:00'::time, :'hall3'::uuid) as _x \gset
select public.save_exam_settings(:'campus_id'::uuid, '{"jummah_cutoff":"14:00"}'::jsonb);
select is((select count(*) from public.fn_datesheet_warnings(:'ds'::uuid) f, jsonb_array_elements(f.warnings) w where w ->> 'code' = 'jummah_conflict'), 0::bigint, 'moving the cut-off to 14:00 clears the Jummah warning');
select throws_ok($$ select public.save_exam_settings(null, '{}'::jsonb) $$, 'CAMPUS_NOT_FOUND', 'settings need a campus');
select throws_ok(format($$ select public.save_exam_settings(%L, '{"cooldown_mode":"maybe"}'::jsonb) $$, :'campus_id'), 'SETTINGS_INVALID', 'an invalid setting value is refused');

-- ── hall double-booking is structural ─────────────────────────────────────
select throws_ok(format($$ select public.save_datesheet_slot(%L, %L, '2026-09-08', '10:00', '11:30', %L) $$, :'ds', :'es_sci', :'hall1'),
  'HALL_DOUBLE_BOOKED', 'a hall cannot hold two papers over overlapping windows');
reset role;
select throws_ok(format($$ insert into public.datesheet_slot (tenant_id, campus_id, datesheet_id, exam_subject_id, start_at, end_at, hall_id)
  select tenant_id, campus_id, datesheet_id, %L, start_at, end_at, hall_id from public.datesheet_slot where id = %L $$, :'es_cs', :'slot_phy'),
  '23P01', null, 'the exclusion constraint refuses it even from a raw insert');

-- ── fn_detect_datesheet_clash sees a clash stored by other means ──────────
insert into public.datesheet_slot (tenant_id, campus_id, datesheet_id, exam_subject_id, start_at, end_at, hall_id)
select tenant_id, campus_id, datesheet_id, :'es_cs'::uuid, start_at + interval '1 hour', end_at + interval '1 hour', null
  from public.datesheet_slot where id = :'slot_phy'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select affected_count from public.fn_detect_datesheet_clash(:'ds'::uuid) limit 1), 12, 'fn_detect_datesheet_clash reports 12 affected');
select is((select cardinality(affected_gr_numbers) from public.fn_detect_datesheet_clash(:'ds'::uuid) limit 1), 12, 'and lists their 12 GR numbers');
select public.delete_datesheet_slot(id) from public.datesheet_slot where datesheet_id = :'ds'::uuid and exam_subject_id = :'es_cs'::uuid;
select is((select count(*) from public.fn_detect_datesheet_clash(:'ds'::uuid)), 0::bigint, 'removing the clashing slot clears the report');

-- ── a published datesheet is read-only ────────────────────────────────────
reset role;
update public.datesheet set status = 'published' where id = :'ds'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_datesheet_slot(%L, %L, '2026-09-12', '09:00', '10:00') $$, :'ds', :'es_phy'), 'DATESHEET_READONLY', 'a published datesheet refuses slot edits');
reset role;
update public.datesheet set status = 'draft' where id = :'ds'::uuid;

-- ── roles and tenants ─────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_datesheet_slot(%L, %L, '2026-09-12', '09:00', '10:00') $$, :'ds', :'es_phy'), 'FORBIDDEN', 'a teacher cannot edit the datesheet');
select is((select count(*) from public.datesheet_slot), 4::bigint, 'but a teacher can read it');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.datesheet_slot) + (select count(*) from public.datesheet), 0::bigint, 'a parent reads no draft datesheet or slot');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.datesheet_slot) + (select count(*) from public.exam_hall) + (select count(*) from public.datesheet), 0::bigint, 'another school sees none of it');
select throws_ok(format($$ select public.create_datesheet(%L, %L, 'x') $$, :'campus_id', :'term1'), 'CAMPUS_NOT_FOUND', 'another school cannot create a datesheet on this campus');

select * from finish();
rollback;
