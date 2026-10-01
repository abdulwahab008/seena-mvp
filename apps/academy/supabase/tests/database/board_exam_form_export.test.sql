-- pgTAP tests for FR-T12: board examination form export and fee reconciliation.
--
--   AC1  300 regular candidates at PKR 2,650 and 12 improvement candidates at
--        PKR 1,900: the reconciliation shows computed PKR 817,800 versus
--        collected PKR 810,500 and lists the 3 students with unpaid board fee.
--   AC2  a Pre-Engineering candidate whose subjects omit a mandatory code for
--        that group is a blocking error naming the missing subject code.
--   AC3  an improvement candidate exports only the subjects being improved, and
--        the fee uses the per-paper improvement rate.
--   AC4  a fee schedule revised mid-cycle: a regenerated export uses the
--        version in force on the session date, not the latest.
--
-- Money is bigint paisa throughout (PKR 2,650 = 265000).
begin;
select plan(41);

select public.provision_tenant('test-board-co', 'Board Co', 'owner@boardco.test');
select id as tenant_id from public.tenant where slug = 'test-board-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-board-rival', 'Board Rival', 'owner@boardrival.test');
select id as rival_id from public.tenant where slug = 'test-board-rival' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as acc_uid \gset
select gen_random_uuid() as teacher_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@boardco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'ec_uid', 'e@boardco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'acc_uid', 'a@boardco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teacher_uid', 't@boardco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@boardrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal'),
  (:'acc_uid', :'tenant_id', 'accountant', 'Accounts Clerk'), (:'teacher_uid', :'tenant_id', 'subject_teacher', 'A Teacher'),
  (:'rival_uid', :'rival_id', 'owner', 'Rival');
insert into public.user_campus (user_id, tenant_id, campus_id) select u, :'tenant_id', :'campus_id'
  from (values (:'ec_uid'::uuid), (:'acc_uid'::uuid), (:'teacher_uid'::uuid)) v(u);

-- ── the fee schedule: PKR 2,650 regular, PKR 1,900 per improvement paper ──
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'acc_uid')::text, true);
select throws_ok(format($$select public.save_board_fee_schedule('FBISE', 2026, 'regular', 0, 0, date '2026-01-01')$$), 'SCHEDULE_INVALID', 'a schedule must charge something');
select public.save_board_fee_schedule('FBISE', 2026, 'regular', 265000, 0, date '2026-01-01', 'FBISE 2026 notification') as sch_reg \gset
select public.save_board_fee_schedule('FBISE', 2026, 'improvement', 0, 190000, date '2026-01-01') as sch_imp \gset
select public.save_board_fee_schedule('PUNJAB', 2026, 'regular', 265000, 0, date '2026-01-01') as sch_pun \gset
select public.save_board_fee_schedule('PUNJAB', 2026, 'improvement', 0, 190000, date '2026-01-01') as sch_pun_imp \gset
select is((select count(*)::int from public.board_fee_schedule), 4, 'the accountant records the schedule');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text, true);
select throws_ok(format($$select public.save_board_fee_schedule('FBISE', 2026, 'private', 100, 0, date '2026-01-01')$$), '42501', null, 'a teacher cannot change fees');
select is((select count(*)::int from public.board_fee_schedule), 4, 'but every staff member can read them (read_all_tenant)');

-- ── 312 candidates, their challans and payments, set-based ───────────────
reset role;
insert into public.fee_head (tenant_id, code, name_en, name_ur, default_frequency) values (:'tenant_id', 'BOARD_EXAM', 'Board Exam Fee', 'بورڈ امتحان فیس', 'one_time') returning id as head \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity) values (:'tenant_id', :'campus_id', :'session_id', :'class9', 'A', 200) returning id as sec \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity) values (:'tenant_id', :'campus_id', :'session_id', :'class9', 'B', 200) returning id as sec_b \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'BX-' || lpad(n::text, 4, '0'), 'Candidate ' || lpad(n::text, 4, '0'), date '2009-01-01', 'male' from generate_series(1, 312) n;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select :'tenant_id', :'campus_id', :'session_id', s.id, :'class9', case when substr(s.gr_number, 4)::int <= 156 then :'sec'::uuid else :'sec_b'::uuid end from public.student s where s.tenant_id = :'tenant_id' and s.gr_number like 'BX-%';

-- 1-300 regular, 301-312 improvement (one paper each).
insert into public.exam_registration (tenant_id, campus_id, session_id, student_id, enrolment_id, board_code, session_year, session_date, roll_no, candidate_category, group_code)
select :'tenant_id', :'campus_id', :'session_id', s.id, e.id, 'FBISE', 2026, date '2026-04-15', 'R' || substr(s.gr_number, 4),
       case when substr(s.gr_number, 4)::int <= 300 then 'regular' else 'improvement' end, 'PRE_ENG'
  from public.student s join public.enrolment e on e.student_id = s.id where s.gr_number like 'BX-%';
insert into public.exam_registration_subject (tenant_id, registration_id, subject_code, election)
select :'tenant_id', r.id, x.code, x.el
  from public.exam_registration r join public.student s on s.id = r.student_id
  cross join lateral (
    select * from (values ('PHY', 'compulsory'), ('CHM', 'compulsory'), ('MTH', 'compulsory')) a(code, el) where r.candidate_category = 'regular'
    union all
    select 'ENG', 'improvement' where r.candidate_category = 'improvement') x
 where s.gr_number like 'BX-%' and r.board_code = 'FBISE';

-- The fee module billed every candidate what the board charges...
insert into public.fee_challan (tenant_id, campus_id, enrolment_id, session_id, billing_period, challan_no, issue_date, due_date,
                                gross_paisa, concession_paisa, arrears_paisa, net_paisa, status)
select :'tenant_id', :'campus_id', e.id, :'session_id', date '2026-03-01', 'BX-CH-' || substr(s.gr_number, 4), date '2026-03-01', date '2026-03-20',
       fee, 0, 0, fee, 'unpaid'
  from public.student s join public.enrolment e on e.student_id = s.id
  cross join lateral (select case when substr(s.gr_number, 4)::int <= 300 then 265000 else 190000 end as fee) f
 where s.gr_number like 'BX-%';
insert into public.fee_challan_line (challan_id, fee_head_id, amount_paisa, concession_paisa, net_paisa, line_type)
select c.id, :'head', c.net_paisa, 0, c.net_paisa, 'charge' from public.fee_challan c where c.challan_no like 'BX-CH-%' and c.tenant_id = :'tenant_id';
-- ...and parents paid it all except three who paid nothing (#1, #2, #301) and
-- one (#3) who paid PKR 2,550 of PKR 2,650.
insert into public.fee_payment (tenant_id, campus_id, enrolment_id, amount_paisa, mode)
select c.tenant_id, c.campus_id, c.enrolment_id,
       case when c.challan_no = 'BX-CH-0003' then 255000 else c.net_paisa end, 'cash'
  from public.fee_challan c where c.challan_no like 'BX-CH-%' and c.tenant_id = :'tenant_id' and c.challan_no not in ('BX-CH-0001', 'BX-CH-0002', 'BX-CH-0301');
insert into public.fee_payment_allocation (payment_id, challan_id, fee_head_id, amount_paisa)
select p.id, c.id, :'head', p.amount_paisa from public.fee_payment p join public.fee_challan c on c.enrolment_id = p.enrolment_id
 where c.challan_no like 'BX-CH-%' and c.tenant_id = :'tenant_id';

-- Bulk-loaded inside this transaction, so the planner has no statistics for the
-- new rows yet; without them the per-candidate lookups below pick nested loops.
analyze public.student;
analyze public.enrolment;
analyze public.fee_challan;
analyze public.fee_challan_line;
analyze public.fee_payment_allocation;
analyze public.exam_registration;
analyze public.exam_registration_subject;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);

-- ── AC1 ───────────────────────────────────────────────────────────────────
select public.fn_board_exam_reconciliation(:'campus_id'::uuid, :'session_id'::uuid, 'FBISE', 2026) as rec \gset
select is((:'rec'::jsonb ->> 'candidates')::int, 312, 'AC1: 312 candidates');
select is((:'rec'::jsonb ->> 'computed_total_paisa')::bigint, 81780000::bigint, 'AC1: computed total is PKR 817,800');
select is((:'rec'::jsonb ->> 'collected_total_paisa')::bigint, 81050000::bigint, 'AC1: collected total is PKR 810,500');
select is((:'rec'::jsonb ->> 'difference_paisa')::bigint, 730000::bigint, 'AC1: the school is PKR 7,300 short of what it must remit');
select is(jsonb_array_length(:'rec'::jsonb -> 'unpaid'), 3, 'AC1: three students have paid no board fee');
select is((select array_agg(x ->> 'gr_number' order by x ->> 'gr_number') from jsonb_array_elements(:'rec'::jsonb -> 'unpaid') x), array['BX-0001', 'BX-0002', 'BX-0301'], 'AC1: and they are named');
select is(jsonb_array_length(:'rec'::jsonb -> 'short'), 1, 'the candidate who paid part of the fee is listed apart');
select is((:'rec'::jsonb -> 'short' -> 0 ->> 'owed_paisa')::bigint, 10000::bigint, 'with the PKR 100 still owed');
select is((:'rec'::jsonb #>> '{by_category,regular,candidates}')::int, 300, 'the regular candidates are counted at the per-candidate rate');
select is((:'rec'::jsonb #>> '{by_category,improvement,computed_paisa}')::bigint, 2280000::bigint, 'the 12 improvement candidates at the per-paper rate: PKR 22,800');
select is(jsonb_array_length(:'rec'::jsonb -> 'billing_mismatch'), 0, 'every challan carries what the board charges');
select is((select payment_status from public.v_board_exam_reconciliation where gr_number = 'BX-0100'), 'paid', 'the view marks a settled candidate paid');
select is((select count(*)::int from public.v_board_exam_reconciliation where payment_status = 'unpaid'), 3, 'and exactly three unpaid');

-- A challan billed at the wrong figure is surfaced, not hidden.
reset role;
update public.fee_challan_line set net_paisa = 275000, amount_paisa = 275000 where challan_id = (select id from public.fee_challan where challan_no = 'BX-CH-0050');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'acc_uid')::text, true);
select is(jsonb_array_length(public.fn_board_exam_reconciliation(:'campus_id'::uuid, :'session_id'::uuid, 'FBISE', 2026) -> 'billing_mismatch'), 1, 'a parent billed PKR 2,750 for a PKR 2,650 fee is flagged');
select is((public.fn_board_exam_reconciliation(:'campus_id'::uuid, :'session_id'::uuid, 'FBISE', 2026) ->> 'candidates')::int, 312, 'the accountant reads the same reconciliation');

-- ── AC4: the schedule is effective-dated ──────────────────────────────────
-- The board revises its regular fee from 1 June. The April session keeps the old one.
select public.save_board_fee_schedule('FBISE', 2026, 'regular', 300000, 0, date '2026-06-01', 'mid-cycle revision') as sch_v2 \gset
select is((select effective_to from public.board_fee_schedule where id = :'sch_reg'), date '2026-05-31', 'AC4: the revision closes the version it replaces the day before');
select is(public.compute_board_exam_fee((select id from public.exam_registration where roll_no = 'R0100'), null), 265000::bigint, 'AC4: a registration for the April session is still priced at the old PKR 2,650');
select is(public.compute_board_exam_fee((select id from public.exam_registration where roll_no = 'R0100'), date '2026-07-01'), 300000::bigint, 'AC4: priced as at a July date it would be PKR 3,000');
select is((select computed_paisa from public.v_board_exam_reconciliation where roll_no = 'R0100'), 265000::bigint, 'AC4: and the reconciliation view uses the session date, not today');
select is((public.fn_board_exam_reconciliation(:'campus_id'::uuid, :'session_id'::uuid, 'FBISE', 2026) ->> 'computed_total_paisa')::bigint, 81780000::bigint, 'AC4: so the computed total is unchanged by the revision');

-- ── AC2, AC3: the export ─────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_student(:'campus_id', 'Zara Engineer', '2009-05-05'::date, 'female', 'Father Z') as st_zara \gset
select public.create_student(:'campus_id', 'Yusuf Improver', '2009-06-06'::date, 'male', 'Father Y') as st_yusuf \gset
select public.create_student(:'campus_id', 'Xena Complete', '2009-07-07'::date, 'female', 'Father X') as st_xena \gset
select public.fn_find_or_create_guardian(p_name_en => 'Zara Mother', p_phone_e164 => '+923005550091') as g_z \gset
select public.link_guardian(:'st_zara'::uuid, :'g_z'::uuid, 'mother'::public.guardian_relationship, true, true);
select public.record_consent(:'st_zara'::uuid, 'third_party_data_sharing', :'g_z'::uuid, 'granted', 'counter');
select public.fn_find_or_create_guardian(p_name_en => 'Yusuf Father', p_phone_e164 => '+923005550092') as g_y \gset
select public.link_guardian(:'st_yusuf'::uuid, :'g_y'::uuid, 'father'::public.guardian_relationship, true, true);
select public.record_consent(:'st_yusuf'::uuid, 'third_party_data_sharing', :'g_y'::uuid, 'granted', 'counter');
select public.fn_find_or_create_guardian(p_name_en => 'Xena Mother', p_phone_e164 => '+923005550093') as g_x \gset
select public.link_guardian(:'st_xena'::uuid, :'g_x'::uuid, 'mother'::public.guardian_relationship, true, true);
select public.record_consent(:'st_xena'::uuid, 'third_party_data_sharing', :'g_x'::uuid, 'granted', 'counter');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'ec_uid')::text, true);
-- Zara is Pre-Engineering but her elective set omits Chemistry.
select public.save_exam_registration(:'st_zara'::uuid, :'session_id'::uuid, 'PUNJAB', 2026, date '2026-04-15', 'regular', 'PRE_ENG', '700001',
  '[{"subject_code":"PHY","election":"compulsory"},{"subject_code":"MTH","election":"compulsory"},{"subject_code":"ENG","election":"compulsory"}]'::jsonb) as reg_zara \gset
-- Yusuf improves two papers, and the registration also carries a compulsory one that must not be exported.
select public.save_exam_registration(:'st_yusuf'::uuid, :'session_id'::uuid, 'PUNJAB', 2026, date '2026-04-15', 'improvement', null, '700002',
  '[{"subject_code":"ENG","election":"improvement"},{"subject_code":"PHY","election":"improvement"},{"subject_code":"URD","election":"compulsory"}]'::jsonb) as reg_yusuf \gset
-- Xena is complete.
select public.save_exam_registration(:'st_xena'::uuid, :'session_id'::uuid, 'PUNJAB', 2026, date '2026-04-15', 'regular', 'PRE_ENG', '700003',
  '[{"subject_code":"PHY","election":"compulsory"},{"subject_code":"CHM","election":"compulsory"},{"subject_code":"MTH","election":"compulsory"}]'::jsonb) as reg_xena \gset

select public.begin_board_exam_form_export(:'campus_id'::uuid, :'session_id'::uuid, 'PUNJAB', 2026) as run \gset
select public.validate_board_exam_form_export(:'run'::uuid) as ready \gset
select is((:'ready'::jsonb ->> 'blocking_count')::int, 1, 'AC2: one blocking error');
select is(:'ready'::jsonb -> 'errors' -> 0 ->> 'rule_code', 'MISSING_MANDATORY_SUBJECT', 'AC2: it is the missing mandatory subject');
select is(:'ready'::jsonb -> 'errors' -> 0 ->> 'subject_code', 'CHM', 'AC2: naming the missing subject code');
select is(:'ready'::jsonb -> 'errors' -> 0 ->> 'student_name', 'Zara Engineer', 'AC2: and the candidate');
select is((:'ready'::jsonb ->> 'can_generate')::boolean, false, 'the export cannot be generated while it is blocked');
select throws_ok(format($$select public.complete_board_exam_form_export(%L, 3, 'x/y.csv', 'abc')$$, :'run'), 'EXPORT_BLOCKED', 'and completing it is refused');

-- Fix the registration: the error clears and the file can be produced.
select public.save_exam_registration(:'st_zara'::uuid, :'session_id'::uuid, 'PUNJAB', 2026, date '2026-04-15', 'regular', 'PRE_ENG', '700001',
  '[{"subject_code":"PHY","election":"compulsory"},{"subject_code":"CHM","election":"compulsory"},{"subject_code":"MTH","election":"compulsory"}]'::jsonb) as _fix \gset
select is((public.validate_board_exam_form_export(:'run'::uuid) ->> 'blocking_count')::int, 0, 'correcting the subjects clears the blocking error');

-- AC3
select public.fn_board_exam_form_rows(:'run'::uuid) as rows \gset
select is((select x -> 'cells' ->> 6 from jsonb_array_elements(:'rows'::jsonb) x where x -> 'cells' ->> 0 = '700002'), 'ENG PHY', 'AC3: the improvement candidate exports only the subjects being improved');
select is((select x -> 'cells' ->> 7 from jsonb_array_elements(:'rows'::jsonb) x where x -> 'cells' ->> 0 = '700002'), '3800.00', 'AC3: at the per-paper rate: 2 x PKR 1,900');
select is((select x -> 'cells' ->> 7 from jsonb_array_elements(:'rows'::jsonb) x where x -> 'cells' ->> 0 = '700003'), '2650.00', 'a regular candidate at the per-candidate rate');
select is(public.fn_board_exam_form_headers(:'run'::uuid) ->> 7, 'Fee (PKR)', 'the file has a fee column');
select is((public.fn_board_exam_form_readiness(:'run'::uuid) ->> 'computed_total_paisa')::bigint, 265000::bigint * 2 + 380000, 'the run carries its computed total: 2 regular + 1 improvement = PKR 9,180');
select lives_ok(format($$select public.complete_board_exam_form_export(%L, 3, 'tenant/run/PUNJAB.csv', %L)$$, :'run', repeat('a', 64)), 'a validated, unblocked run completes');

-- Regenerating after the mid-cycle revision still prices the April session on the April schedule.
select public.save_board_fee_schedule('PUNJAB', 2026, 'regular', 300000, 0, date '2026-06-01') as _v2 \gset
select public.begin_board_exam_form_export(:'campus_id'::uuid, :'session_id'::uuid, 'PUNJAB', 2026) as run2 \gset
select public.validate_board_exam_form_export(:'run2'::uuid) as _v \gset
select is((select x -> 'cells' ->> 7 from jsonb_array_elements(public.fn_board_exam_form_rows(:'run2'::uuid)) x where x -> 'cells' ->> 0 = '700003'), '2650.00', 'AC4: a regenerated export uses the schedule in force on the session date, not the latest');

-- ── who sees ──────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text, true);
select is((select count(*)::int from public.exam_registration) + (select count(*)::int from public.v_board_exam_reconciliation), 0, 'a teacher sees no registrations or reconciliation');
select throws_ok(format($$select public.begin_board_exam_form_export(%L, %L, 'PUNJAB', 2026)$$, :'campus_id', :'session_id'), '42501', null, 'and cannot start an export');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select is((select count(*)::int from public.v_board_exam_reconciliation) + (select count(*)::int from public.board_fee_schedule) + (select count(*)::int from public.board_exam_form_export), 0, 'another school sees nothing');

select * from finish();
rollback;
