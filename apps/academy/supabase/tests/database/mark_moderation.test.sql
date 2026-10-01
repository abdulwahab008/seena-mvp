-- pgTAP tests for FR-I15: head of department moderation.
--
--   AC1  +4 with a reason: every Present candidate's theory mark rises by 4,
--        capped at the component maximum, and the candidates who hit the cap
--        are listed.
--   AC2  A configured cap of 5 and an attempted +9: refused, naming the cap.
--   AC3  A second moderation of the same section and subject is refused until the
--        first is explicitly reversed (and the partial unique index guarantees it).
--   AC4  Marks already approved: refused, break-glass required.
begin;
select plan(50);

select public.provision_tenant('test-moderation-co', 'Moderation Co', 'owner@moderation.test');
select id as tenant_id from public.tenant where slug = 'test-moderation-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-moderation-other', 'Other Moderation Co', 'owner@othermoderation.test');
select id as other_tenant_id from public.tenant where slug = 'test-moderation-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@moderation.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@moderation.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'pr@moderation.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@moderation.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'pa@moderation.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Rukhsana Bano'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'parent_uid', :'tenant_id', 'parent', 'Parent');

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
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', :'s_phy', 5::smallint) as cs_phy \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'B', 45) as sec_b \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as t1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'t1', :'cs_phy', '[{"component":"theory","max_marks":65,"pass_marks":23}]'::jsonb) as es_phy \gset

reset role;
-- 10 pupils per section. Section A: 1-6 scored 25 (38%), 7 scored 62, 8 scored 65, 9 scored 25, 10 was absent. Section B scored 55.
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'GR-' || lpad(g::text, 3, '0'), 'Pupil ' || g, date '2011-01-01', 'male' from generate_series(1, 20) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', st.id, :'class9', case when n <= 10 then :'sec_a'::uuid else :'sec_b'::uuid end, ((n - 1) % 10) + 1
  from (select id, right(gr_number, 3)::int as n from public.student where tenant_id = :'tenant_id') st;
insert into public.mark_entry (tenant_id, campus_id, exam_subject_id, enrolment_id, component_code, marks_obtained, status)
select :'tenant_id', :'campus_id', :'es_phy', e.id, 'theory',
       case when st.n between 1 and 6 then 25 when st.n = 7 then 62 when st.n = 8 then 65 when st.n = 9 then 25 else 55 end, 'draft'
  from public.enrolment e join (select id, right(gr_number, 3)::int as n from public.student where tenant_id = :'tenant_id') st on st.id = e.student_id
 where st.n <> 10;
insert into public.exam_attendance (tenant_id, campus_id, exam_subject_id, enrolment_id, status, reason)
select :'tenant_id', :'campus_id', :'es_phy', e.id, 'absent', 'medical' from public.enrolment e join public.student st on st.id = e.student_id where st.gr_number = 'GR-010';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── the picture the controller sees first ─────────────────────────────────
select public.fn_moderation_context(:'es_phy'::uuid, :'sec_a'::uuid) as ctx \gset
select is((:'ctx'::jsonb ->> 'present_with_marks')::int, 9, 'section A has 9 present candidates with a mark (the absent one has none)');
select is((:'ctx'::jsonb ->> 'section_mean_pct')::numeric, round(((6 * 25 + 62 + 65 + 25)::numeric / 9) * 100 / 65, 2), 'the section mean is shown against the component maximum');
select ok((:'ctx'::jsonb ->> 'section_mean_pct')::numeric < (:'ctx'::jsonb ->> 'class_mean_pct')::numeric, 'and it is below the class mean');
select is((:'ctx'::jsonb ->> 'cap_delta')::numeric, 5::numeric, 'the default cap is 5 marks');
select is((:'ctx'::jsonb ->> 'approved')::boolean, false, 'the marks are not approved');

-- ── guards before anything moves ──────────────────────────────────────────
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 4, 'too short') $$, :'es_phy', :'sec_a'), 'REASON_TOO_SHORT', 'a reason under 20 characters is refused');
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 0, 'paper harder than blueprint, Q7 outside the chapters') $$, :'es_phy', :'sec_a'), 'DELTA_REQUIRED', 'a zero adjustment is refused');
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 1.5, 'paper harder than blueprint, Q7 outside the chapters') $$, :'es_phy', :'sec_a'), 'MODERATION_PRECISION', 'a fractional adjustment is refused where the campus records whole marks');
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 4, 'paper harder than blueprint, Q7 outside the chapters') $$, :'es_phy', :'sec_a'::text || 'x'), '22P02', null, 'a malformed section id is not accepted');

-- ── AC2: the cap ──────────────────────────────────────────────────────────
select pg_temp.cap(format($$ select public.fn_apply_moderation(%L, %L, 9, 'paper harder than blueprint, Q7 outside the chapters') $$, :'es_phy', :'sec_a')) as cap_msg \gset
select is(split_part(:'cap_msg'::text, ' | ', 1), 'MODERATION_CAP_EXCEEDED: 5', 'AC2: +9 is refused and the message carries the cap value (5)');
select ok(:'cap_msg'::text like '%The maximum moderation is 5 marks.%', 'AC2: and says so in words');
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, -9, 'paper harder than blueprint, Q7 outside the chapters') $$, :'es_phy', :'sec_a'), 'MODERATION_CAP_EXCEEDED: 5', 'AC2: a downward adjustment is bounded the same way');
select public.save_exam_settings(:'campus_id'::uuid, '{"max_moderation_pct":5}'::jsonb);
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 4, 'paper harder than blueprint, Q7 outside the chapters') $$, :'es_phy', :'sec_a'), 'MODERATION_CAP_EXCEEDED: 5%', 'a percentage cap (5% of 65 = 3.25 marks) also binds');
select public.save_exam_settings(:'campus_id'::uuid, '{"max_moderation_pct":null}'::jsonb);
select is((select count(*) from public.mark_moderation), 0::bigint, 'nothing was moderated by any refusal');
select is((select count(*) from public.mark_entry where status = 'moderated'), 0::bigint, 'and no mark moved');

-- ── AC1: +4 ───────────────────────────────────────────────────────────────
select public.fn_apply_moderation(:'es_phy'::uuid, :'sec_a'::uuid, 4, 'paper harder than blueprint, Q7 outside prescribed chapters') as mod1 \gset
select is((:'mod1'::jsonb ->> 'affected')::int, 9, 'AC1: nine present candidates are moderated');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_a'::uuid and m.marks_obtained = 29), 7::bigint, 'AC1: the seven who scored 25 now have 29');
select is((select max(marks_obtained) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_a'::uuid), 65::numeric, 'AC1: nobody exceeds the component maximum of 65');
select is((:'mod1'::jsonb ->> 'capped_count')::int, 2, 'AC1: two candidates hit the cap');
select is((select array_agg(c ->> 'gr_number' order by c ->> 'gr_number') from jsonb_array_elements((:'mod1'::jsonb) -> 'capped') c), array['GR-007', 'GR-008'], 'AC1: and they are listed (GR-007 would have been 66, GR-008 69)');
select is((select (c ->> 'after')::numeric from jsonb_array_elements((:'mod1'::jsonb) -> 'capped') c where c ->> 'gr_number' = 'GR-007'), 65::numeric, 'AC1: capped to 65');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_a'::uuid and m.status = 'moderated'), 9::bigint, 'moderated marks carry the status "moderated"');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_b'::uuid and m.marks_obtained = 55), 10::bigint, 'the other section is untouched');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id join public.student st on st.id = e.student_id where st.gr_number = 'GR-010'), 0::bigint, 'the absent candidate gained no mark');
select is((select reason from public.mark_moderation where id = (:'mod1'::jsonb ->> 'moderation_id')::uuid), 'paper harder than blueprint, Q7 outside prescribed chapters', 'the reason is stored');
select is((select applied_by from public.mark_moderation where id = (:'mod1'::jsonb ->> 'moderation_id')::uuid), :'ec_uid'::uuid, 'with the actor');
select is((select before_marks from public.mark_moderation_entry me join public.enrolment e on e.id = me.enrolment_id join public.student st on st.id = e.student_id where me.moderation_id = (:'mod1'::jsonb ->> 'moderation_id')::uuid and st.gr_number = 'GR-007'), 62::numeric, 'the pre-moderation value is kept in the audit table');
select ok((select section_mean_pct < class_mean_pct from public.mark_moderation where id = (:'mod1'::jsonb ->> 'moderation_id')::uuid), 'and so are the section and class means the decision was made against');

-- ── AC3: once only ────────────────────────────────────────────────────────
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 2, 'a second moderation of the very same section') $$, :'es_phy', :'sec_a'), 'MODERATION_EXISTS', 'AC3: a second moderation of the same section and subject is refused');
select ok(exists (select 1 from pg_indexes where indexname = 'uq_moderation_open' and indexdef like '%WHERE (reversed_at IS NULL)%'), 'AC3: and the partial unique index makes it structurally impossible');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_a'::uuid and m.marks_obtained = 29), 7::bigint, 'AC3: the first moderation stands');
select throws_ok(format($$ select public.fn_reverse_moderation(%L, 'x') $$, (:'mod1'::jsonb ->> 'moderation_id')), 'REASON_TOO_SHORT', 'reversal also needs a reason');
select public.fn_reverse_moderation((:'mod1'::jsonb ->> 'moderation_id')::uuid, 'Applied to the wrong section by mistake') as rev \gset
select is((:'rev'::jsonb ->> 'restored')::int, 9, 'AC3: reversing restores all nine marks');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_a'::uuid and m.marks_obtained = 25 and m.status = 'draft'), 7::bigint, 'AC3: to their original value and status');
select is((select marks_obtained from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id join public.student st on st.id = e.student_id where st.gr_number = 'GR-007'), 62::numeric, 'including the one that had been capped');
select throws_ok(format($$ select public.fn_reverse_moderation(%L, 'Applied to the wrong section by mistake') $$, (:'mod1'::jsonb ->> 'moderation_id')), 'MODERATION_ALREADY_REVERSED', 'a reversal cannot be repeated');
select lives_ok(format($$ select public.fn_apply_moderation(%L, %L, 3, 'a fresh moderation after the explicit reversal') $$, :'es_phy', :'sec_a'), 'AC3: after the explicit reversal a new moderation is allowed');
reset role;
update public.mark_entry set marks_obtained = 30 where id = (select m.id from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id join public.student st on st.id = e.student_id where st.gr_number = 'GR-001');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.fn_reverse_moderation((select id from public.mark_moderation where section_id = :'sec_a'::uuid and reversed_at is null), 'The teacher re-marked one script meanwhile') as rev2 \gset
select is(((:'rev2'::jsonb ->> 'skipped')::int, (:'rev2'::jsonb ->> 'restored')::int), (1, 8), 'a mark the teacher re-entered since is left alone, the rest restored');
select is((select marks_obtained from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id join public.student st on st.id = e.student_id where st.gr_number = 'GR-001'), 30::numeric, 'the re-entered mark keeps the teacher''s value');

-- ── AC4: approved marks ───────────────────────────────────────────────────
reset role;
update public.mark_entry set status = 'approved' where id = (select m.id from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id join public.student st on st.id = e.student_id where st.gr_number = 'GR-011');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.cap(format($$ select public.fn_apply_moderation(%L, %L, 2, 'paper was harder than the blueprint allowed') $$, :'es_phy', :'sec_b')) as appr \gset
select is(split_part(:'appr'::text, ' | ', 1), 'MARKS_APPROVED', 'AC4: moderating a section with approved marks is refused');
select ok(:'appr'::text like '%break-glass%', 'AC4: and points at the break-glass path');
select is((select count(*) from public.mark_entry m join public.enrolment e on e.id = m.enrolment_id where e.section_id = :'sec_b'::uuid and m.marks_obtained = 55), 10::bigint, 'AC4: nothing moved');

-- ── roles, immutability, tenants ──────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.fn_apply_moderation(%L, %L, 2, 'paper was harder than the blueprint allowed') $$, :'es_phy', :'sec_b'), 'FORBIDDEN', 'a teacher cannot moderate');
select is((select count(*) from public.mark_moderation) + (select count(*) from public.mark_moderation_entry), 0::bigint, 'and cannot read moderations');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.mark_moderation) >= 2 and (select count(*) from public.mark_moderation_entry) >= 18, 'the Principal reads the moderations and their entries');
update public.mark_moderation set reason = 'rewritten history of the moderation';
select is((select count(*) from public.mark_moderation where reason like 'rewritten%'), 0::bigint, 'a client cannot rewrite a moderation''s reason (no write policy)');
delete from public.mark_moderation;
select ok((select count(*) from public.mark_moderation) >= 2, 'or delete a moderation');
reset role;
select throws_ok($$ update public.mark_moderation set reason = 'rewritten history of the moderation' $$, '42501', null, 'even the table owner cannot rewrite the reason (trigger)');
select throws_ok($$ delete from public.mark_moderation $$, '42501', null, 'or delete a moderation');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.mark_moderation) + (select count(*) from public.mark_moderation_entry), 0::bigint, 'another school sees none of it');


select * from finish();
rollback;
