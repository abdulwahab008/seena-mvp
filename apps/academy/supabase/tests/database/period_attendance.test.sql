-- pgTAP tests for FR-G03: period-wise attendance for senior classes.
begin;
select plan(32);

select public.provision_tenant('test-period-co', 'Period Co', 'owner@period.test');
select id as tenant_id from public.tenant where slug = 'test-period-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-period-other', 'Other Period Co', 'owner@otherperiod.test');
select id as other_tenant_id from public.tenant where slug = 'test-period-other' \gset
select set_config('t.campus', :'campus_id', false), set_config('t.section', 'pending', false);

-- a working day that is not a Sunday and is not in the future
select (case when extract(dow from app.fn_karachi_today()) = 0 then app.fn_karachi_today() - 1 else app.fn_karachi_today() end) as d \gset
select extract(dow from :'d'::date)::smallint as dow \gset
select set_config('t.d', :'d', false);

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as t1_uid \gset
select gen_random_uuid() as t2_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@period.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@period.test', 'authenticated', 'authenticated', 'x'),
  (:'t1_uid', 't1@period.test', 'authenticated', 'authenticated', 'x'), (:'t2_uid', 't2@period.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'t1_uid', :'tenant_id', 'subject_teacher', 'Physics Teacher'), (:'t2_uid', :'tenant_id', 'subject_teacher', 'CS Teacher');

insert into public.subject (tenant_id, code, name_en, name_ur) values
  (:'tenant_id', 'PHY', 'Physics', 'طبیعیات'), (:'tenant_id', 'MTH', 'Maths', 'ریاضی'), (:'tenant_id', 'CS', 'Computer Science', 'کمپیوٹر'), (:'tenant_id', 'MTHE', 'Advanced Maths', 'ریاضی');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
select id as mth from public.subject where tenant_id = :'tenant_id' and code = 'MTH' \gset
select id as cs from public.subject where tenant_id = :'tenant_id' and code = 'CS' \gset
select id as mthe from public.subject where tenant_id = :'tenant_id' and code = 'MTHE' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select set_config('t.section', :'section_id', false);
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_mode => 'period', p_lock_window_hours => 720);
create temp table kid (n int primary key, enrol_id uuid, student_id uuid);
grant all on kid to authenticated;
do $$
declare i int; v_s uuid;
begin
  for i in 1..4 loop
    v_s := public.create_student(current_setting('t.campus')::uuid, 'Period Kid ' || i, '2010-01-01'::date, 'male');
    insert into kid values (i, public.enrol_student(current_setting('t.section')::uuid, v_s), v_s);
  end loop;
end $$;
reset role;

-- a published timetable for that weekday: 8 periods, period 6 is an elective block (CS or Advanced Maths)
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, published_at, version_no)
values (:'tenant_id', :'campus_id', :'session_id', 'MORNING', 'Period test', 'PUBLISHED', now(), 1) returning id as ver \gset
insert into public.timetable_parallel_group (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, elective_bucket)
values (:'tenant_id', :'campus_id', :'ver', :'section_id', :'dow', 6, 1) returning id as grp \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id, elective_bucket, parallel_group_id)
select :'tenant_id', :'campus_id', :'ver', :'section_id', :'dow', p, case when p = 4 then :'phy'::uuid else :'mth'::uuid end, case when p = 4 then :'t1_uid'::uuid else null end, null, null
  from generate_series(1, 8) p where p <> 6;
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id, elective_bucket, parallel_group_id) values
  (:'tenant_id', :'campus_id', :'ver', :'section_id', :'dow', 6, :'cs', :'t2_uid', 1, :'grp'),
  (:'tenant_id', :'campus_id', :'ver', :'section_id', :'dow', 6, :'mthe', null, 1, :'grp');
select id as slot4 from public.timetable_slot where timetable_version_id = :'ver' and period_no = 4 \gset
select id as slot5 from public.timetable_slot where timetable_version_id = :'ver' and period_no = 5 \gset
select id as slot6cs from public.timetable_slot where timetable_version_id = :'ver' and subject_id = :'cs' \gset
select id as slot6m from public.timetable_slot where timetable_version_id = :'ver' and subject_id = :'mthe' \gset
insert into public.student_elective_choice (tenant_id, campus_id, student_id, session_id, class_level_id, elective_bucket, subject_id)
select :'tenant_id', :'campus_id', student_id, :'session_id', :'class1_id', 1, case when n <= 2 then :'cs'::uuid else :'mthe'::uuid end from kid;

-- ── AC3: the elective lists only its own students ─────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.period_attendance_roster(:'slot6cs'::uuid, :'d'::date)), 2::bigint, 'AC3: the Computer Science elective lists its 2 students, not the 4-student section');
select is((select string_agg(student_name, ',' order by student_name) from public.period_attendance_roster(:'slot6cs'::uuid, :'d'::date)), 'Period Kid 1,Period Kid 2', 'and they are the ones who chose it');
select throws_ok(format($$ select public.save_period_attendance(%L, %L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'slot6cs', :'d', (select enrol_id from kid where n = 3)), 'STUDENT_NOT_ON_THIS_ROSTER', 'a student from the other elective cannot be marked into it');

-- ── AC2: a teacher only reaches their own period ──────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.period_attendance_roster(:'slot4'::uuid, :'d'::date)), 4::bigint, 'the Physics teacher sees the full roster of period 4');
select throws_ok(format($$ select * from public.period_attendance_roster(%L, %L) $$, :'slot5', :'d'), 'NOT_ASSIGNED_TO_THIS_PERIOD', 'AC2: period 5 is refused with "not assigned to this period"');
select throws_ok(format($$ select public.save_period_attendance(%L, %L, '[]'::jsonb) $$, :'slot5', :'d'), 'NOT_ASSIGNED_TO_THIS_PERIOD', 'and so is marking it');
select is((select count(*) from public.period_attendance_slots(:'d'::date)), 1::bigint, 'the slot picker offers only period 4');
select public.save_period_attendance(:'slot4'::uuid, :'d'::date, (select jsonb_agg(jsonb_build_object('enrolment_id', enrol_id, 'status', 'absent')) from kid)) as saved4 \gset
select is((:'saved4'::jsonb ->> 'saved')::int, 4, 'the teacher saves period 4 for all four students');
select is((select count(*) from public.attendance_period), 4::bigint, 'RLS lets the teacher see only their period''s rows');
select is((select count(*) from public.attendance_period where timetable_slot_id = :'slot5'::uuid), 0::bigint, 'AC2: and zero rows for period 5');

-- ── mode, date and timetable guards ───────────────────────────────────────
select throws_ok(format($$ select public.save_period_attendance(%L, %L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'slot4', (:'d'::date + 7), (select enrol_id from kid where n = 1)), '22023', null, 'a future date is refused');
select throws_ok(format($$ select public.save_period_attendance(%L, %L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'slot4', (:'d'::date - 1), (select enrol_id from kid where n = 1)), 'DATE_NOT_ON_SLOT_WEEKDAY', 'a date on a different weekday is refused');
reset role;
update public.timetable_version set status = 'DRAFT' where id = :'ver'::uuid;
set local role authenticated;
select throws_ok(format($$ select public.save_period_attendance(%L, %L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'slot4', :'d', (select enrol_id from kid where n = 1)), 'TIMETABLE_NOT_PUBLISHED', 'an unpublished timetable cannot be marked');
reset role;
update public.timetable_version set status = 'PUBLISHED' where id = :'ver'::uuid;
insert into public.attendance_policy (tenant_id, campus_id, session_id, mode, lock_window_hours) values (:'tenant_id', :'campus_id', :'session_id', 'daily', 720);
set local role authenticated;
select throws_ok(format($$ select public.save_period_attendance(%L, %L, jsonb_build_array(jsonb_build_object('enrolment_id', %L, 'status', 'present'))) $$, :'slot4', :'d', (select enrol_id from kid where n = 1)), 'CAMPUS_NOT_IN_PERIOD_MODE', 'a campus on daily attendance cannot mark by period');
reset role;
delete from public.attendance_policy where tenant_id = :'tenant_id' and mode = 'daily';

-- ── AC1: 3 of 8 periods present gives a half day, derived ─────────────────
-- Everyone starts absent in period 4 (saved above). Owner marks the rest by pattern:
--   kid 1 present in periods 1-3 (3 of 8), kid 2 in 4 of 8, kid 3 in none, kid 4 in all 8.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
do $$
declare s record; v_marks jsonb;
begin
  for s in select ts.id, ts.period_no, ts.subject_id from public.timetable_slot ts
            where ts.timetable_version_id = (select id from public.timetable_version where name = 'Period test') and ts.period_no <> 4
  loop
    select jsonb_agg(jsonb_build_object('enrolment_id', r.enrolment_id, 'status',
             case k.n when 1 then case when s.period_no <= 3 then 'present' else 'absent' end
                      when 2 then case when s.period_no in (1, 2, 3, 5) then 'present' else 'absent' end
                      when 3 then 'absent'
                      else 'present' end))
      into v_marks
      from public.period_attendance_roster(s.id, current_setting('t.d')::date) r join kid k on k.enrol_id = r.enrolment_id;
    perform public.save_period_attendance(s.id, current_setting('t.d')::date, v_marks);
  end loop;
end $$;
reset role;

select is((select count(*) from public.attendance_period), 32::bigint, 'four students each have a row for all eight periods');
select is((select count(*) from public.attendance_day where attendance_date = :'d'::date and source = 'derived'), 0::bigint, 'nothing is published to the day register before derivation runs');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.derive_day_from_periods(:'campus_id'::uuid, :'d'::date), 4, 'the derivation covers the four students with period marks');
reset role;
select is((select status::text || '/' || source::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 1) and attendance_date = :'d'::date), 'half_day/derived', 'AC1: present in 3 of 8 periods gives a half day, source derived');
select is((select status::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 2) and attendance_date = :'d'::date), 'present', 'present in exactly half the periods is still present');
select is((select status::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 3) and attendance_date = :'d'::date), 'absent', 'present in none gives absent');
select is((select status::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 4) and attendance_date = :'d'::date), 'present', 'present in nearly all gives present');
select is((select count(*) from public.attendance_day where attendance_date = :'d'::date and source = 'derived'), 4::bigint, 'four derived day rows exist');

-- ── AC4: editing a period after derivation re-derives that day at once ────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_period_attendance(:'slot4'::uuid, :'d'::date, jsonb_build_array(jsonb_build_object('enrolment_id', (select enrol_id from kid where n = 1), 'status', 'present')));
reset role;
select is((select status::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 1) and attendance_date = :'d'::date), 'present', 'AC4: correcting period 4 lifts the day from half_day to present immediately (4 of 8)');

-- ── the manual day mark always wins, and the disagreement is flagged ──────
update public.attendance_day set status = 'present', source = 'web' where enrolment_id = (select enrol_id from kid where n = 3) and attendance_date = :'d'::date;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_period_attendance(:'slot4'::uuid, :'d'::date, jsonb_build_array(jsonb_build_object('enrolment_id', (select enrol_id from kid where n = 3), 'status', 'excused')));
reset role;
select is((select status::text || '/' || source::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 3) and attendance_date = :'d'::date), 'present/web', 'a manual mark is not overwritten by the derivation');
select is((select derived_status::text || ' vs ' || manual_status::text from public.attendance_derivation_conflict where enrolment_id = (select enrol_id from kid where n = 3)), 'absent vs present', 'and the disagreement is recorded for review');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.derive_day_from_periods(:'campus_id'::uuid, :'d'::date);
select public.derive_day_from_periods(:'campus_id'::uuid, :'d'::date);
select is((select count(*) from public.attendance_derivation_conflict), 1::bigint, 'running the nightly derivation again keeps one conflict row, not more');
select is((select source::text from public.attendance_day where enrolment_id = (select enrol_id from kid where n = 3) and attendance_date = :'d'::date), 'web', 'and still does not touch the manual row');
update public.attendance_day set status = 'absent' where enrolment_id = (select enrol_id from kid where n = 3) and attendance_date = :'d'::date;
select public.derive_day_from_periods(:'campus_id'::uuid, :'d'::date);
select is((select count(*) from public.attendance_derivation_conflict), 0::bigint, 'once the manual mark agrees with the periods the conflict clears');

-- ── substitution gives the covering teacher access for that date ──────────
insert into public.timetable_substitution (tenant_id, campus_id, slot_id, sub_date, absent_staff_id, substitute_staff_id, reason)
values (:'tenant_id', :'campus_id', :'slot5', :'d', :'t1_uid', :'t2_uid', 'leave');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.period_attendance_roster(:'slot5'::uuid, :'d'::date)), 4::bigint, 'a teacher covering period 5 that day can open it');

-- ── scope ─────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.period_attendance_slots(:'d'::date)), 9::bigint, 'a Principal sees every slot of the campus for that weekday');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select * from public.period_attendance_roster(%L, %L) $$, :'slot4', :'d'), 'SLOT_NOT_FOUND', 'another school cannot open this school''s slot');
select is((select count(*) from public.attendance_period), 0::bigint, 'and sees none of its period rows');

select * from finish();
rollback;
