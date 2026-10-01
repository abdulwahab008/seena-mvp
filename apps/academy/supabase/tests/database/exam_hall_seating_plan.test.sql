-- pgTAP tests for FR-I09: exam hall seating plan.
--
--   AC1  120 candidates from 3 sections, a hall of 10 x 12: everyone holds exactly
--        one seat and the violation report is empty.
--   AC2  130 candidates, 120 seats: capacity_shortfall: 10, naming the halls free
--        for that window.
--   AC3  Two paper sets: adjacent seats alternate set code (and the chart that
--        feeds the seat slips carries the letter).
--   AC4  One late admission and a regeneration: at least 95% (here all) of the
--        existing candidates keep their seat.
begin;
select plan(39);

select public.provision_tenant('test-seating-co', 'Seating Co', 'owner@seating.test');
select id as tenant_id from public.tenant where slug = 'test-seating-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-seating-other', 'Other Seating Co', 'owner@otherseating.test');
select id as other_tenant_id from public.tenant where slug = 'test-seating-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@seating.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@seating.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@seating.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@seating.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
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
select public.create_subject(c, 'Subject ' || c, 'مضمون') from unnest(array['SA', 'SB', 'SC', 'SD', 'SF', 'SG', 'EL']) c;
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', s.id, 4::smallint) from public.subject s where s.tenant_id = :'tenant_id' and s.code in ('SA', 'SB', 'SC', 'SD', 'SF', 'SG');
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', s.id, 4::smallint, null, false, 1::smallint, 1::smallint) from public.subject s where s.tenant_id = :'tenant_id' and s.code = 'EL';
select id as sub_el from public.subject where tenant_id = :'tenant_id' and code = 'EL' \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 60) as sec_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'B', 60) as sec_b \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'C', 60) as sec_c \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', cs.id, '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb) from public.class_subject cs where cs.tenant_id = :'tenant_id';
select es.id as es_sa from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SA' \gset
select es.id as es_sb from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SB' \gset
select es.id as es_sc from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SC' \gset
select es.id as es_sd from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SD' \gset
select es.id as es_sf from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SF' \gset
select es.id as es_sg from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'SG' \gset
select es.id as es_el from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject s on s.id = cs.subject_id where es.tenant_id = :'tenant_id' and s.code = 'EL' \gset

reset role;
-- 120 pupils: 40 per section, roll numbers 1..40.
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'GR-' || lpad(g::text, 4, '0'), 'Pupil ' || g, date '2011-01-01', 'male' from generate_series(1, 120) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', st.id, :'class9',
       case when n <= 40 then :'sec_a'::uuid when n <= 80 then :'sec_b'::uuid else :'sec_c'::uuid end, ((n - 1) % 40) + 1
  from (select id, right(gr_number, 4)::int as n from public.student where tenant_id = :'tenant_id') st;
-- The elective: 40 from A, 20 from B, 5 from C choose it - section A is over half the room.
insert into public.student_elective_choice (tenant_id, campus_id, student_id, session_id, class_level_id, elective_bucket, subject_id)
select :'tenant_id', :'campus_id', st.id, :'session_id', :'class9', 1, :'sub_el'
  from public.student st where st.tenant_id = :'tenant_id' and (right(st.gr_number, 4)::int between 1 and 40 or right(st.gr_number, 4)::int between 41 and 60 or right(st.gr_number, 4)::int between 81 and 85);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_exam_hall(:'campus_id'::uuid, 'H1', 'Main Hall', 10, 12) as h1 \gset
select public.save_exam_hall(:'campus_id'::uuid, 'H2', 'Hall Two', 10, 13) as h2 \gset
select public.save_exam_hall(:'campus_id'::uuid, 'H4', 'Hall Four', 10, 13) as h4 \gset
select public.save_exam_hall(:'campus_id'::uuid, 'H5', 'Hall Five', 10, 15) as h5 \gset
select public.save_exam_hall(:'campus_id'::uuid, 'H6', 'Hall Six', 10, 13) as h6 \gset
select is((select count(*) from public.exam_hall_seat where hall_id = :'h1'::uuid), 120::bigint, 'a hall of 10 x 12 gets 120 seats');
select public.create_datesheet(:'campus_id'::uuid, :'term1'::uuid, 'First Term datesheet') as ds \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sa'::uuid, '2026-09-08'::date, '09:00'::time, '11:00'::time, :'h1'::uuid) ->> 'slot_id' as slot_sa \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sb'::uuid, '2026-09-09'::date, '09:00'::time, '11:00'::time, :'h2'::uuid) ->> 'slot_id' as slot_sb \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sc'::uuid, '2026-09-10'::date, '09:00'::time, '11:00'::time, :'h1'::uuid) ->> 'slot_id' as slot_sc \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sd'::uuid, '2026-09-12'::date, '09:00'::time, '11:00'::time, :'h4'::uuid) ->> 'slot_id' as slot_sd \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_el'::uuid, '2026-09-14'::date, '09:00'::time, '11:00'::time, :'h5'::uuid) ->> 'slot_id' as slot_el \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sf'::uuid, '2026-09-15'::date, '09:00'::time, '11:00'::time) ->> 'slot_id' as slot_sf \gset
select public.save_datesheet_slot(:'ds'::uuid, :'es_sg'::uuid, '2026-09-16'::date, '09:00'::time, '11:00'::time, :'h6'::uuid) ->> 'slot_id' as slot_sg \gset

-- ── AC1 ───────────────────────────────────────────────────────────────────
select is(public.fn_generate_seating_plan(:'slot_sa'::uuid), 120, 'AC1: 120 candidates are seated');
select is((select count(distinct enrolment_id) from public.exam_seat_allocation where slot_id = :'slot_sa'::uuid), 120::bigint, 'AC1: every candidate holds a seat');
select is((select count(*) from public.exam_seat_allocation where slot_id = :'slot_sa'::uuid), 120::bigint, 'AC1: and exactly one');
select is((select count(*) from public.fn_seating_violations(:'slot_sa'::uuid)), 0::bigint, 'AC1: the violation report has zero adjacency violations');
select is((select count(distinct section_id) from public.exam_seat_allocation where slot_id = :'slot_sa'::uuid), 3::bigint, 'AC1: all three sections are in the room');
select is((select count(*) from public.exam_seat_allocation a join public.exam_seat_allocation b on b.slot_id = a.slot_id and b.row_no = a.row_no and b.seat_no = a.seat_no + 1 and b.section_id = a.section_id where a.slot_id = :'slot_sa'::uuid), 0::bigint, 'AC1: checked independently - no two benchmates share a section');
select throws_ok(format($$ insert into public.exam_seat_allocation (tenant_id, campus_id, slot_id, hall_id, row_no, seat_no, enrolment_id, section_id)
  select tenant_id, campus_id, slot_id, hall_id, row_no, seat_no, enrolment_id, section_id from public.exam_seat_allocation where slot_id = %L limit 1 $$, :'slot_sa'),
  '42501', null, 'the seating table takes no direct writes from a client');

-- ── AC4: a late admission and a regeneration ──────────────────────────────
select public.fn_generate_seating_plan(:'slot_sb'::uuid) as _g \gset
create temp table before_late as select enrolment_id, row_no, seat_no from public.exam_seat_allocation where slot_id = :'slot_sb'::uuid;
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender) values (:'tenant_id', :'campus_id', 'GR-0121', 'Late Admission', date '2011-02-02', 'female');
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', st.id, :'class9', :'sec_a', 41 from public.student st where st.tenant_id = :'tenant_id' and st.gr_number = 'GR-0121';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.fn_generate_seating_plan(:'slot_sb'::uuid), 121, 'AC4: the regenerated plan seats the late admission too');
select ok((select count(*) filter (where a.row_no = b.row_no and a.seat_no = b.seat_no)::numeric / count(*) from before_late b join public.exam_seat_allocation a on a.slot_id = :'slot_sb'::uuid and a.enrolment_id = b.enrolment_id) >= 0.95, 'AC4: at least 95% of existing candidates kept their seat');
select is((select count(*) from before_late b join public.exam_seat_allocation a on a.slot_id = :'slot_sb'::uuid and a.enrolment_id = b.enrolment_id and (a.row_no, a.seat_no) = (b.row_no, b.seat_no)), 120::bigint, 'AC4: in fact all 120 kept the very same seat');
select is((select count(*) from public.fn_seating_violations(:'slot_sb'::uuid)), 0::bigint, 'AC4: and the new plan is still violation-free');
select is(public.fn_generate_seating_plan(:'slot_sb'::uuid), 121, 'regenerating again changes nothing');
select is((select count(*) from before_late b join public.exam_seat_allocation a on a.slot_id = :'slot_sb'::uuid and a.enrolment_id = b.enrolment_id and (a.row_no, a.seat_no) = (b.row_no, b.seat_no)), 120::bigint, 'and nobody moved');

-- ── AC2: 130 candidates, 120 seats ────────────────────────────────────────
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'GR-' || lpad((121 + g)::text, 4, '0'), 'Extra ' || g, date '2011-03-03', 'male' from generate_series(1, 9) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', st.id, :'class9', :'sec_b', 41 + right(st.gr_number, 4)::int - 121 from public.student st where st.tenant_id = :'tenant_id' and right(st.gr_number, 4)::int between 122 and 130;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select pg_temp.cap(format($$ select public.fn_generate_seating_plan(%L) $$, :'slot_sc')) as short_msg \gset
select ok(:'short_msg'::text like 'capacity_shortfall: 10%', 'AC2: 130 candidates in 120 seats fails with capacity_shortfall: 10');
select ok(:'short_msg'::text like '%Hall Two (130 seats)%', 'AC2: and lists the halls with free capacity for that window');
select is((select count(*) from public.exam_seat_allocation where slot_id = :'slot_sc'::uuid), 0::bigint, 'AC2: nothing is half-seated');
select is((select count(*) from public.fn_halls_free_for_slot(:'slot_sc'::uuid) where code = 'H2' and available_seats = 130), 1::bigint, 'AC2: the structured list names Hall Two with 130 seats');

-- ── AC3: two paper sets ───────────────────────────────────────────────────
select public.upsert_paper_set_group(:'es_sd'::uuid, 2);
select is(public.fn_generate_seating_plan(:'slot_sd'::uuid), 130, 'AC3: 130 candidates seated in a hall of 130');
select is((select count(*) from public.exam_seat_allocation a join public.exam_seat_allocation b on b.slot_id = a.slot_id and b.row_no = a.row_no and b.seat_no = a.seat_no + 1 and b.set_code = a.set_code where a.slot_id = :'slot_sd'::uuid), 0::bigint, 'AC3: adjacent seats never share a set code');
select is((select array_agg(distinct set_code::text order by set_code::text) from public.exam_seat_allocation where slot_id = :'slot_sd'::uuid), array['A', 'B'], 'AC3: both sets are in use');
select is((select count(*) from public.fn_seating_violations(:'slot_sd'::uuid)), 0::bigint, 'AC3: and the violation report (sections and sets) is empty');
select is((select count(*) from jsonb_array_elements(public.fn_seating_chart(:'slot_sd'::uuid) -> 'allocations') x where x ->> 'set_code' in ('A', 'B')), 130::bigint, 'AC3: every seat slip in the chart carries its set letter');
select is((public.fn_seating_chart(:'slot_sd'::uuid) ->> 'set_count')::int, 2, 'the chart records the number of sets');
select throws_ok(format($$ select public.upsert_paper_set_group(%L, 5) $$, :'es_sd'), 'SET_COUNT_INVALID', 'a paper is printed in 1 to 4 sets');

-- ── one section more than half the room: spare seats are used as gaps ─────
select is(public.fn_generate_seating_plan(:'slot_el'::uuid), 65, '65 elective candidates (40 + 20 + 5) are seated');
select is((select count(*) from public.fn_seating_violations(:'slot_el'::uuid)), 0::bigint, 'even with one section over half the room there is no adjacency violation');
-- A broken desk is never used, and only its occupant moves.
create temp table before_desk as select enrolment_id, row_no, seat_no from public.exam_seat_allocation where slot_id = :'slot_el'::uuid;
select public.set_hall_seat_available(:'h5'::uuid, 1, 1, false);
select is(public.fn_generate_seating_plan(:'slot_el'::uuid), 65, 'after a desk breaks the plan still seats everyone');
select is((select count(*) from public.exam_seat_allocation where slot_id = :'slot_el'::uuid and row_no = 1 and seat_no = 1), 0::bigint, 'nobody is on the broken desk');
select is((select count(*) from before_desk b join public.exam_seat_allocation a on a.slot_id = :'slot_el'::uuid and a.enrolment_id = b.enrolment_id and (a.row_no, a.seat_no) = (b.row_no, b.seat_no)), 64::bigint, 'and only the displaced candidate moved');

-- ── strategy, missing hall, hall resize ───────────────────────────────────
select is(public.fn_generate_seating_plan(:'slot_sg'::uuid, 'sequential'), 130, 'sequential (roll order) seating is available');
select ok((select count(*) from public.fn_seating_violations(:'slot_sg'::uuid)) > 0, 'and the violation report shows what that costs');
select throws_ok(format($$ select public.fn_generate_seating_plan(%L, 'random') $$, :'slot_sd'), 'STRATEGY_INVALID', 'an unknown strategy is refused');
select throws_ok(format($$ select public.fn_generate_seating_plan(%L) $$, :'slot_sf'), 'SLOT_HALL_REQUIRED', 'a slot without a hall cannot be seated');
select throws_ok(format($$ select public.save_exam_hall(%L, 'H5', 'Hall Five', 3, 15) $$, :'campus_id'), 'HALL_SEATS_IN_USE', 'a hall cannot shrink under allocated seats');

-- ── roles and tenants ─────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.fn_generate_seating_plan(%L) $$, :'slot_sa'), 'FORBIDDEN', 'a teacher cannot generate a plan');
select ok((select count(*) from public.exam_seat_allocation) > 0, 'but a teacher (invigilator) can read the plans');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.exam_seat_allocation) + (select count(*) from public.exam_hall_seat), 0::bigint, 'a parent reads no seating data');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.exam_seat_allocation) + (select count(*) from public.exam_hall_seat) + (select count(*) from public.exam_paper_set_group), 0::bigint, 'another school sees none of it');

select * from finish();
rollback;
