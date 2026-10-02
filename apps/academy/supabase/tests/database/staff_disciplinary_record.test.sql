-- pgTAP tests for FR-D15: restricted disciplinary action record.
begin;
select plan(33);

select public.provision_tenant('test-disc-co', 'Disc Co', 'owner@disc.test');
select id as tenant_id from public.tenant where slug = 'test-disc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-disc-other', 'Other Disc Co', 'owner@otherdisc.test');
select id as other_tenant_id from public.tenant where slug = 'test-disc-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as prin2_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@disc.test', 'authenticated', 'authenticated', 'x'), (:'hr_uid', 'h@disc.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'p@disc.test', 'authenticated', 'authenticated', 'x'), (:'prin2_uid', 'p2@disc.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@disc.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'),
  (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'prin2_uid', :'tenant_id', 'principal', 'Issuing Principal'),
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Suspended Teacher');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, full_name) values
  (:'tenant_id', :'campus_id', :'teach_uid', 'DS-1', '42101-1111111-1', 'male', 'Suspended Teacher'),
  (:'tenant_id', :'campus_id', null, 'DS-2', '42101-1111111-2', 'female', 'Other Staff');
select id as s1 from public.staff where employee_code = 'DS-1' and tenant_id = :'tenant_id' \gset
select id as s2 from public.staff where employee_code = 'DS-2' and tenant_id = :'tenant_id' \gset

-- a published timetable with two Monday periods for the teacher
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
reset role;
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'PHY', 'Physics', 'طبیعیات');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
insert into public.timetable_version (tenant_id, campus_id, session_id, shift, name, status, version_no, effective_from, effective_to, published_at)
values (:'tenant_id', :'campus_id', :'session_id', 'MORNING', 'v1', 'PUBLISHED', 1, '2026-07-01', '2026-12-31', now());
select id as tv from public.timetable_version where tenant_id = :'tenant_id' \gset
insert into public.timetable_slot (tenant_id, campus_id, timetable_version_id, section_id, weekday, period_no, subject_id, staff_id) values
  (:'tenant_id', :'campus_id', :'tv', :'sec', 1, 1, :'phy', :'teach_uid'), (:'tenant_id', :'campus_id', :'tv', :'sec', 1, 2, :'phy', :'teach_uid');

-- ── issuing: server-generated stamps, role gates ─────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin2_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_disciplinary_action(:'s2'::uuid, 'warning', 'Repeated lateness') as warn \gset
select throws_ok(format($$ select public.issue_disciplinary_action(%L::uuid, 'termination', 'x') $$, :'s2'), 'FORBIDDEN', 'a Principal cannot issue a termination');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.issue_disciplinary_action(%L::uuid, 'warning', 'x') $$, :'s2'), 'FORBIDDEN', 'a teacher cannot issue anything');
reset role;
select is((select issued_on from public.staff_disciplinary where id = :'warn'::uuid), app.fn_karachi_today(), 'issued_on is the server date, not client input');
select ok((select abs(extract(epoch from now() - created_at)) < 5 from public.staff_disciplinary where id = :'warn'::uuid), 'created_at is the server clock');

-- ── AC1: only HR, the Owner and the issuer can read ──────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.staff_disciplinary), 0::bigint, 'AC1: a Principal who is not the issuer gets zero rows from a direct table read');
select throws_ok(format($$ select * from public.list_staff_disciplinary(%L::uuid) $$, :'s2'), 'FORBIDDEN', 'AC1: and the profile section call is refused');
select set_config('request.jwt.claims', json_build_object('sub', :'prin2_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.staff_disciplinary), 1::bigint, 'the issuing Principal still sees the row they issued');
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.staff_disciplinary), 1::bigint, 'HR reads every row');

-- ── AC2: a 7-day show-cause is overdue when day 8 begins ─────────────────
select public.issue_disciplinary_action(:'s2'::uuid, 'show_cause', 'Unauthorised absence on 12 July', 7::smallint) as sc \gset
select is((select response_due_on - issued_on from public.staff_disciplinary where id = :'sc'::uuid), 7, 'the deadline is 7 days after issue');
select is((select count(*) from public.list_overdue_showcause(app.fn_karachi_today() + 6)), 0::bigint, 'AC2: still within the window on day 7');
select is((select count(*) from public.list_overdue_showcause(app.fn_karachi_today() + 7)), 1::bigint, 'AC2: on the HR overdue worklist when day 8 begins');
select public.supersede_disciplinary_record(:'sc'::uuid, p_staff_response => 'I was at the board office; see attached letter.') as sc2 \gset
select is((select count(*) from public.list_overdue_showcause(app.fn_karachi_today() + 30)), 0::bigint, 'a recorded response clears the overdue entry');
select ok((select responded_at is not null and staff_response is not null and supersedes_id = :'sc'::uuid from public.staff_disciplinary where id = :'sc2'::uuid), 'the response is a new row referencing supersedes_id with a server timestamp');
reset role;
select is(public.flag_overdue_showcause(app.fn_karachi_today() + 30), 0, 'the daily job flags nothing for an answered notice');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_disciplinary_action(:'s2'::uuid, 'show_cause', 'Second notice', 3::smallint) as sc3 \gset
reset role;
select is(public.flag_overdue_showcause(app.fn_karachi_today() + 10), 1, 'the daily job flags the unanswered notice once');
select is(public.flag_overdue_showcause(app.fn_karachi_today() + 10), 0, 'and re-running it flags nothing twice');

-- ── AC3: suspension => read-only role and substitution feed ──────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.issue_disciplinary_action(:'s1'::uuid, 'suspension', 'Pending inquiry', null, '2026-08-01'::date, '2026-08-15'::date) as susp \gset
select ok(public.is_staff_suspended(:'s1'::uuid, '2026-08-01') and public.is_staff_suspended(:'s1'::uuid, '2026-08-15'), 'AC3: suspended on the first and last day');
select ok(not public.is_staff_suspended(:'s1'::uuid, '2026-07-31') and not public.is_staff_suspended(:'s1'::uuid, '2026-08-16'), 'AC3: not suspended outside the window');
select is(public.effective_app_role(:'teach_uid'::uuid, '2026-08-05'), 'read_only', 'AC3: effective role is read_only during the window');
select is(public.effective_app_role(:'teach_uid'::uuid, '2026-08-20'), 'subject_teacher', 'and the real role again afterwards');
select is((select count(*) from public.get_suspension_cover_feed(:'campus_id'::uuid, '2026-08-01', '2026-08-15')), 4::bigint, 'AC3: both Monday periods on 3 and 10 August surface in the substitution feed');
select is((select count(*) from public.get_suspension_cover_feed(:'campus_id'::uuid, '2026-08-16', '2026-08-31')), 0::bigint, 'no feed rows after the suspension ends');
select is((select count(*) from public.get_suspended_teachers(:'campus_id'::uuid, '2026-08-05')), 1::bigint, 'the Substitutions page lists the suspended teacher as unavailable');

-- ── AC4: no delete, no update; corrections are new rows ──────────────────
select throws_ok($$ delete from public.staff_disciplinary $$, '42501', null, 'AC4: HR cannot DELETE a disciplinary row');
select throws_ok($$ update public.staff_disciplinary set description = 'edited' $$, '42501', null, 'AC4: nor UPDATE it');
reset role;
select throws_ok(format($$ delete from public.staff_disciplinary where id = %L $$, :'warn'), '42501', 'DISCIPLINARY_IMMUTABLE', 'AC4: even a privileged session is stopped by the trigger');
select throws_ok(format($$ update public.staff_disciplinary set outcome = 'x' where id = %L $$, :'warn'), '42501', 'DISCIPLINARY_IMMUTABLE', 'AC4: updates are refused too');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.supersede_disciplinary_record(:'warn'::uuid, p_description => 'Repeated lateness (corrected: 3 times, not 5)') as warn2 \gset
select is((select supersedes_id from public.staff_disciplinary where id = :'warn2'::uuid), :'warn'::uuid, 'AC4: the correction is a new row referencing supersedes_id');
select throws_ok(format($$ select public.supersede_disciplinary_record(%L::uuid, 'again') $$, :'warn'), 'ALREADY_SUPERSEDED', 'a row can be superseded only once');
select public.reinstate_suspended_staff(:'susp'::uuid, 'Inquiry closed');
select ok(not public.is_staff_suspended(:'s1'::uuid, '2026-08-05'), 'a reinstatement row ends the suspension early');
select is((select count(*) from public.get_suspension_cover_feed(:'campus_id'::uuid, '2026-08-01', '2026-08-15')), 0::bigint, 'and the periods leave the cover feed');
reset role;

-- ── the audit trail does not leak what the table hides ───────────────────
select is((select after ->> 'description' from public.audit_log where table_name = 'staff_disciplinary' and row_id = :'warn'::uuid and action = 'insert'), '[redacted]', 'audit_log shows [redacted] for the description');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.staff_disciplinary), 0::bigint, 'another school sees none');

select * from finish();
rollback;
