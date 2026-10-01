-- pgTAP tests for FR-I10: invigilation duty roster.
--
--   AC1  8 slots, 20 eligible staff, a cap of 5: every slot gets its configured
--        invigilators, nobody exceeds 5, and the spread between the busiest and
--        the least busy member is at most 2.
--   AC2  A teacher of the paper's subject to that class is excluded from that slot.
--   AC3  Approved leave excludes a member for that date, and a duty already on
--        that date raises a substitution task.
--   AC4  When no feasible assignment exists the under-staffed slots are reported
--        by name, not silently under-assigned.
-- Plus the manual exclusion list (the roster runs without HR leave data), the
-- overlap rule, the hr_manager / self-read policies and the roster notice.
begin;
select plan(36);

select public.provision_tenant('test-invig-co', 'Invigilation Co', 'owner@invig.test');
select id as tenant_id from public.tenant where slug = 'test-invig-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-invig-other', 'Other Invigilation Co', 'owner@otherinvig.test');
select id as other_tenant_id from public.tenant where slug = 'test-invig-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as outsider_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@invig.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@invig.test', 'authenticated', 'authenticated', 'x'),
  (:'hr_uid', 'h@invig.test', 'authenticated', 'authenticated', 'x'), (:'outsider_uid', 'x@invig.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'),
  (:'hr_uid', :'tenant_id', 'hr_manager', 'HR Manager'), (:'outsider_uid', :'tenant_id', 'subject_teacher', 'Outsider');

-- 20 staff with logins: staff1 is "Ms. Ayesha".
insert into auth.users (id, email, aud, role, encrypted_password)
select gen_random_uuid(), 'staff' || g || '@invig.test', 'authenticated', 'authenticated', 'x' from generate_series(1, 20) g;
insert into public.app_user (user_id, tenant_id, app_role, full_name)
select u.id, :'tenant_id', 'subject_teacher', 'Staff ' || substring(u.email from 'staff(\d+)@')::int
  from auth.users u where u.email like 'staff%@invig.test';
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, full_name)
select :'tenant_id', :'campus_id', u.id, 'EMP' || n, lpad(n::text, 5, '1') || '-' || lpad(n::text, 7, '0') || '-1', 'female', case when n = 1 then 'Ms. Ayesha' else 'Staff ' || n end
  from (select id, substring(email from 'staff(\d+)@')::int as n from auth.users where email like 'staff%@invig.test') u(id, n);
select user_id as ayesha_uid, id as ayesha_staff from public.staff where tenant_id = :'tenant_id' and employee_code = 'EMP1' \gset
select user_id as staff2_uid, id as staff2_staff from public.staff where tenant_id = :'tenant_id' and employee_code = 'EMP2' \gset
select user_id as staff3_uid from public.staff where tenant_id = :'tenant_id' and employee_code = 'EMP3' \gset

-- The evaluator is internal (no client may call it); the tests read it through a definer wrapper.
create function pg_temp.blocked(p_slot uuid, p_user uuid) returns text language sql security definer as
  $$ select blocked_by from app.fn_invigilator_evaluate(p_slot) where user_id = p_user $$;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('S' || g, 'Subject ' || g, 'مضمون ' || g) from generate_series(1, 8) g;
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', s.id, 4::smallint) from public.subject s where s.tenant_id = :'tenant_id' and s.code like 'S%';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec9 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'W1', 'Weekly Test', 2::smallint, 0.00, false) as term2 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', cs.id, '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb) from public.class_subject cs where cs.tenant_id = :'tenant_id';
select id as s1 from public.subject where tenant_id = :'tenant_id' and code = 'S1' \gset
reset role;
-- Ms. Ayesha teaches Subject 1 (the "Chemistry" of the story) to Class 9-A.
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from)
values (:'tenant_id', :'campus_id', :'session_id', :'sec9', :'s1', :'ayesha_uid', current_date - 90);
insert into public.leave_type (tenant_id, code, name_en, entitlement_days) values (:'tenant_id', 'CASUAL', 'Casual leave', 10);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_datesheet(:'campus_id'::uuid, :'term1'::uuid, 'First Term datesheet') as ds \gset
select public.create_datesheet(:'campus_id'::uuid, :'term2'::uuid, 'Weekly datesheet') as ds2 \gset
-- One paper a day from 8 Sept, two invigilators each. Subject 1 is first.
select public.save_datesheet_slot(:'ds'::uuid, x.id, (date '2026-09-07' + x.n)::date, '09:00'::time, '11:00'::time, null, 2)
  from (select es.id, (row_number() over (order by sub.code))::int as n
          from public.exam_subject es join public.class_subject cs on cs.id = es.class_subject_id join public.subject sub on sub.id = cs.subject_id
         where es.tenant_id = :'tenant_id' and es.exam_term_id = :'term1') x;
select id as slot_s1 from public.datesheet_slot where datesheet_id = :'ds'::uuid order by start_at limit 1 \gset
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 8::bigint, 'the datesheet has 8 slots');

-- ── AC1: automatic, capped, fair ──────────────────────────────────────────
select public.assign_invigilation(:'ds'::uuid) as run1 \gset
select is((:'run1'::jsonb ->> 'assigned_now')::int, 16, 'AC1: 8 slots x 2 invigilators = 16 duties assigned');
select is((select count(*) from public.datesheet_slot s where s.datesheet_id = :'ds'::uuid
            and (select count(*) from public.invigilation_duty d where d.datesheet_slot_id = s.id and d.status = 'assigned') = 2), 8::bigint, 'AC1: every slot has its configured invigilator count');
select is(jsonb_array_length(:'run1'::jsonb -> 'understaffed'), 0, 'AC1: nothing is under-staffed');
select ok((select max(c) <= 5 from (select count(*) c from public.invigilation_duty where exam_term_id = :'term1' and status = 'assigned' group by staff_id) q), 'AC1: nobody exceeds the cap of 5');
select ok(((:'run1'::jsonb -> 'spread' ->> 'max')::int - (:'run1'::jsonb -> 'spread' ->> 'min')::int) <= 2, 'AC1: the spread between the busiest and least busy is at most 2');
select ok((select count(distinct staff_id) from public.invigilation_duty where exam_term_id = :'term1') = 16, 'the load is spread over 16 different people rather than piled on a few');

-- ── AC2: the paper's own teacher is excluded ──────────────────────────────
select is(pg_temp.blocked(:'slot_s1'::uuid, :'ayesha_uid'::uuid), 'own_subject', 'AC2: Ms. Ayesha is blocked from her own subject''s slot');
select is((select count(*) from public.invigilation_duty where datesheet_slot_id = :'slot_s1'::uuid and staff_id = :'ayesha_uid'::uuid), 0::bigint, 'AC2: and was not assigned to it');
select isnt(pg_temp.blocked((select id from public.datesheet_slot where datesheet_id = :'ds'::uuid order by start_at desc limit 1), :'ayesha_uid'::uuid), 'own_subject', 'she is not blocked on papers of other subjects');
select throws_ok(format($$ select public.add_invigilation_duty(%L, %L) $$, :'slot_s1', :'ayesha_uid'), 'STAFF_NOT_ELIGIBLE: own_subject', 'AC2: a manual add cannot put her on it either');

-- ── AC3: approved leave, and a duty already on that date ──────────────────
select d.staff_id as leave_uid, d.datesheet_slot_id as leave_slot, (s.start_at at time zone 'Asia/Karachi')::date as leave_date
  from public.invigilation_duty d join public.datesheet_slot s on s.id = d.datesheet_slot_id
 where d.exam_term_id = :'term1' and d.status = 'assigned' order by s.start_at limit 1 \gset
select id as leave_staff from public.staff where user_id = :'leave_uid' \gset
reset role;
insert into public.leave_application (tenant_id, campus_id, staff_id, leave_type_id, from_date, to_date, working_days, status)
select :'tenant_id', :'campus_id', :'leave_staff', lt.id, :'leave_date'::date, :'leave_date'::date, 1, 'approved'
  from public.leave_type lt where lt.tenant_id = :'tenant_id' and lt.code = 'CASUAL';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(pg_temp.blocked(:'leave_slot'::uuid, :'leave_uid'::uuid), 'on_leave', 'AC3: a member on approved leave that day is excluded');
select public.assign_invigilation(:'ds'::uuid) as run2 \gset
select is((select status from public.invigilation_duty where datesheet_slot_id = :'leave_slot'::uuid and staff_id = :'leave_uid'::uuid), 'substitution_needed', 'AC3: the existing duty on the leave date is flagged');
select is((select reason from public.invigilation_substitution_task t join public.invigilation_duty d on d.id = t.duty_id where d.staff_id = :'leave_uid'::uuid and d.datesheet_slot_id = :'leave_slot'::uuid), 'staff_on_leave', 'AC3: and a substitution task is raised for it');
select is((select count(*) from public.invigilation_duty where datesheet_slot_id = :'leave_slot'::uuid and status = 'assigned'), 2::bigint, 'the same run fills the freed place with someone else');
select is((select t.status from public.invigilation_substitution_task t join public.invigilation_duty d on d.id = t.duty_id where d.staff_id = :'leave_uid'::uuid and d.datesheet_slot_id = :'leave_slot'::uuid), 'resolved', 'so the task is resolved with a replacement');
select is((select count(*) from public.invigilation_substitution_task), 1::bigint, 'running again raises no duplicate task');
select public.assign_invigilation(:'ds'::uuid);
select is((select count(*) from public.invigilation_substitution_task), 1::bigint, 'AC3: the substitution task is idempotent');

-- ── no HR data needed: the manual exclusion list does the same job ────────
select d.staff_id as ex_uid, d.datesheet_slot_id as ex_slot, (s.start_at at time zone 'Asia/Karachi')::date as ex_date
  from public.invigilation_duty d join public.datesheet_slot s on s.id = d.datesheet_slot_id
 where d.exam_term_id = :'term1' and d.status = 'assigned' and d.staff_id <> :'leave_uid' order by s.start_at desc limit 1 \gset
select public.add_invigilation_exclusion(:'term1'::uuid, :'ex_uid'::uuid, :'ex_date'::date, 'Family wedding') as excl \gset
select is(pg_temp.blocked(:'ex_slot'::uuid, :'ex_uid'::uuid), 'excluded', 'a manual exclusion blocks the member for that date');
select is(public.flag_invigilation_conflicts(:'ds'::uuid), 1, 'and flags the duty they already held that day');
select is((select reason from public.invigilation_substitution_task t join public.invigilation_duty d on d.id = t.duty_id where d.staff_id = :'ex_uid'::uuid and d.datesheet_slot_id = :'ex_slot'::uuid), 'excluded', 'with an "excluded" substitution task');
select throws_ok(format($$ select public.add_invigilation_exclusion(%L, %L, null, 'x') $$, :'term1', :'ex_uid'), 'EXCLUSION_TARGET_INVALID', 'an exclusion needs a date or a slot');
select lives_ok(format($$ select public.remove_invigilation_exclusion(%L) $$, :'excl'), 'an exclusion can be withdrawn');

-- ── overlap: nobody on two papers at once ─────────────────────────────────
select is((select count(*) from public.invigilation_duty d1 join public.invigilation_duty d2 on d1.staff_id = d2.staff_id and d1.id < d2.id
             join public.datesheet_slot s1 on s1.id = d1.datesheet_slot_id join public.datesheet_slot s2 on s2.id = d2.datesheet_slot_id
            where d1.status = 'assigned' and d2.status = 'assigned' and tstzrange(s1.start_at, s1.end_at) && tstzrange(s2.start_at, s2.end_at)), 0::bigint, 'nobody is rostered on two overlapping papers');

-- ── AC4: no feasible assignment -> the shortfall is named ─────────────────
reset role;
insert into public.exam_subject (tenant_id, campus_id, exam_term_id, class_subject_id)
select :'tenant_id', :'campus_id', :'term2', cs.id from public.class_subject cs where cs.tenant_id = :'tenant_id' and cs.subject_id = :'s1';
select es.id as es_w from public.exam_subject es where es.exam_term_id = :'term2' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.save_datesheet_slot(:'ds2'::uuid, :'es_w'::uuid, '2026-09-20'::date, '09:00'::time, '11:00'::time, null, 25) ->> 'slot_id' as slot_w \gset
select public.assign_invigilation(:'ds2'::uuid) as run3 \gset
select is(jsonb_array_length(:'run3'::jsonb -> 'understaffed'), 1, 'AC4: the under-staffed slot is reported');
select is((:'run3'::jsonb -> 'understaffed' -> 0 ->> 'slot_id')::uuid, :'slot_w'::uuid, 'AC4: by its id');
select is((:'run3'::jsonb -> 'understaffed' -> 0 ->> 'shortfall')::int, 6, 'AC4: with the exact shortfall (25 needed, 19 eligible because Ms. Ayesha teaches it)');
select is((:'run3'::jsonb -> 'understaffed' -> 0 -> 'pool' ->> 'own_subject')::int, 1, 'AC4: and the reason breakdown names why');
select is((select count(*) from public.invigilation_duty where datesheet_slot_id = :'slot_w'::uuid and status = 'assigned'), 19::bigint, 'everyone eligible was used rather than silently stopping early');

-- ── roster notice ─────────────────────────────────────────────────────────
select ok(public.notify_duty_roster(:'ds'::uuid) >= 15, 'the roster notice goes to everyone with a duty');
select is(public.notify_duty_roster(:'ds'::uuid), 0, 'and not twice');

-- ── visibility ────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'staff3_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.invigilation_duty where staff_id <> :'staff3_uid'::uuid) = 0, 'a member reads only their own duties (duty_self_read)');
select throws_ok(format($$ select public.assign_invigilation(%L) $$, :'ds'), 'FORBIDDEN', 'a teacher cannot run the roster');
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.invigilation_duty) >= 35 and (select count(*) from public.invigilation_substitution_task) >= 1, 'the HR manager reads every duty and task of the campus');
select throws_ok(format($$ select public.remove_invigilation_duty(%L) $$, (select id from public.invigilation_duty limit 1)), 'FORBIDDEN', 'but cannot change them');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.invigilation_duty) + (select count(*) from public.invigilation_constraint) + (select count(*) from public.invigilation_substitution_task), 0::bigint, 'another school sees none of it');

select * from finish();
rollback;
