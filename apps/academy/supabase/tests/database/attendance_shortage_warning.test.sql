-- pgTAP tests for FR-G16: attendance shortage warning generation.
begin;
select plan(28);

select public.provision_tenant('test-shortage-co', 'Shortage Co', 'owner@shortage.test');
select id as tenant_id from public.tenant where slug = 'test-shortage-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-shortage-other', 'Other Shortage Co', 'owner@othershortage.test');
select id as other_tenant_id from public.tenant where slug = 'test-shortage-other' \gset
update public.academic_session set starts_on = current_date - 100, ends_on = current_date + 200, status = 'active' where id = :'session_id'::uuid;
select set_config('t.campus', :'campus_id', false), set_config('t.section', 'pending', false);

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as ct_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@shortage.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@shortage.test', 'authenticated', 'authenticated', 'x'),
  (:'ct_uid', 'c@shortage.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@shortage.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'ct_uid', :'tenant_id', 'class_teacher', 'Class Teacher'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
select set_config('t.section', :'section_id', false);
create temp table kid (n int primary key, enrol_id uuid, student_id uuid);
grant all on kid to authenticated;
do $$
declare i int; v_s uuid;
begin
  for i in 1..4 loop
    v_s := public.create_student(current_setting('t.campus')::uuid, 'Shortage Kid ' || i, '2012-01-01'::date, 'male');
    insert into kid values (i, public.enrol_student(current_setting('t.section')::uuid, v_s), v_s);
  end loop;
end $$;
select public.fn_find_or_create_guardian(p_name_en => 'Shortage Father', p_phone_e164 => '+923006660001') as g1 \gset
select public.link_guardian((select student_id from kid where n = 1), :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
update public.guardian set preferred_language = 'ur' where id = :'g1'::uuid;

-- n recorded days, p of them present, ending yesterday
create or replace function pg_temp.mark(p_n int, p_days int, p_present int) returns void language sql as $$
  insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source)
  select e.tenant_id, e.campus_id, e.session_id, e.section_id, e.id, current_date - g, case when g <= p_present then 'present' else 'absent' end::public.student_attendance_status, 'web'
    from public.enrolment e, generate_series(1, p_days) g where e.id = (select enrol_id from kid where n = p_n)
  on conflict (enrolment_id, attendance_date) do update set status = excluded.status;
$$;
select pg_temp.mark(1, 35, 25);
select pg_temp.mark(2, 35, 25);
select pg_temp.mark(3, 35, 25);
select pg_temp.mark(4, 19, 0);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_attendance_policy(p_campus_id => :'campus_id'::uuid, p_session_id => :'session_id'::uuid, p_min_attendance_pct => 75);
select throws_ok(format($$ select public.evaluate_attendance_shortage(%L, %L) $$, gen_random_uuid(), :'session_id'), 'CAMPUS_NOT_FOUND', 'an unknown campus is refused');

-- ── AC1 and AC4: level 1, and a 19-day sample is ignored ──────────────────
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid) as run1 \gset
select is((:'run1'::jsonb ->> 'raised')::int, 3, 'AC1: the three students under 75% with enough data each get a warning');
select is((:'run1'::jsonb ->> 'skipped')::int, 1, 'AC4: the student with 19 recorded days is skipped');
select is((select level::text || '/' || pct_at_warning::text from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1)), '1/71.43', 'AC1: a level-1 warning records the percentage at the time (25 of 35 = 71.43)');
select is((select count(*) from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 4)), 0::bigint, 'AC4: no warning below 20 recorded days');

-- ── the parent is told, in their language ─────────────────────────────────
reset role;
select is((select count(*) from public.message where idempotency_key like 'shortage:%' and recipient_type = 'guardian' and recipient_phone = '+923006660001'), 1::bigint, 'the guardian gets one SMS for the level-1 warning');
select ok((select body like '%71.43%' and body like '%محترم%' from public.message where idempotency_key like 'shortage:%' and recipient_phone = '+923006660001'), 'in Urdu, with the percentage');

-- ── cadence: a second run the same day changes nothing ────────────────────
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid) as run2 \gset
select is((:'run2'::jsonb ->> 'escalated')::int, 0, 'running again straight away does not escalate');
select is((select count(*) from public.message where idempotency_key like 'shortage:%' and recipient_phone = '+923006660001'), 1::bigint, 'and sends nothing more');

-- ── AC2: the next weekly run escalates the same warning ───────────────────
update public.attendance_shortage_warning set last_escalated_at = now() - interval '7 days' where tenant_id = :'tenant_id';
select pg_temp.mark(1, 35, 23);
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid) as run3 \gset
select is((select level from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1) and status = 'open'), 2::smallint, 'AC2: the open warning moves to level 2');
select is((select count(*) from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1)), 1::bigint, 'AC2: there is still one warning, not a second level-1');
select is((select pct_at_warning from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1)), 65.71, 'with the percentage at the escalation (23 of 35)');
select is((select count(*) from public.message where idempotency_key = 'shortage:' || (select id from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1)) || ':2'), 1::bigint, 'and a second notice goes to the parent');

-- ── AC5: level 3 also notifies the Principal ──────────────────────────────
select is((select count(*) from public.user_notification where kind = 'attendance_shortage_l3'), 0::bigint, 'no Principal notification before level 3');
update public.attendance_shortage_warning set last_escalated_at = now() - interval '7 days' where tenant_id = :'tenant_id';
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid);
select is((select level from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1) and status = 'open'), 3::smallint, 'the third evaluation reaches level 3');
select is((select count(*) from public.user_notification where kind = 'attendance_shortage_l3' and user_id = :'prin_uid'::uuid), 3::bigint, 'AC5: the Principal is notified of each level-3 warning');
update public.attendance_shortage_warning set last_escalated_at = now() - interval '7 days' where tenant_id = :'tenant_id';
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid);
select is((select level from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 1) and status = 'open'), 3::smallint, 'level 3 is the ceiling');
select is((select count(*) from public.user_notification where kind = 'attendance_shortage_l3' and user_id = :'prin_uid'::uuid), 3::bigint, 'and is not re-announced');

-- ── AC3: recovery closes the warning ──────────────────────────────────────
select pg_temp.mark(3, 35, 35);
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid) as run6 \gset
select is((select status || '/' || closed_reason from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 3)), 'recovered/recovered', 'AC3: a student back above 75% has the warning closed as recovered');
select is((:'run6'::jsonb ->> 'recovered')::int, 1, 'and it is counted as recovered');
update public.attendance_shortage_warning set last_escalated_at = now() - interval '7 days' where tenant_id = :'tenant_id' and status = 'open';
select public.evaluate_attendance_shortage(:'campus_id'::uuid, :'session_id'::uuid);
select is((select count(*) from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 3)), 1::bigint, 'no further warning follows a recovery');

-- ── no threshold, no warnings ─────────────────────────────────────────────
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'B', 'Campus B') returning id as campus_b \gset
select is((public.evaluate_attendance_shortage(:'campus_b'::uuid, :'session_id'::uuid) ->> 'threshold'), null, 'a campus with no min_attendance_pct raises nothing');

-- ── closing, access, isolation ────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ct_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.attendance_shortage_warning where status = 'open'), 2::bigint, 'a class teacher sees the open warnings of the campus');
select throws_ok(format($$ select public.close_shortage_warning(%L, 'short') $$, (select id from public.attendance_shortage_warning where status = 'open' limit 1)), 'REASON_MIN_LENGTH_10', 'closing needs a reason');
select public.close_shortage_warning((select id from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 2) and status = 'open'), 'Condoned on medical grounds');
select is((select status from public.attendance_shortage_warning where enrolment_id = (select enrol_id from kid where n = 2) order by raised_at desc limit 1), 'closed', 'a class teacher can close a warning with a reason');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.evaluate_attendance_shortage(%L, %L) $$, :'campus_id', :'session_id'), 'FORBIDDEN', 'a subject teacher cannot run the evaluation');
select is((select count(*) from public.attendance_shortage_warning), 0::bigint, 'and cannot read warnings');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.evaluate_attendance_shortage(%L, %L) $$, :'campus_id', :'session_id'), 'CAMPUS_NOT_FOUND', 'another school cannot evaluate this one');

select * from finish();
rollback;
