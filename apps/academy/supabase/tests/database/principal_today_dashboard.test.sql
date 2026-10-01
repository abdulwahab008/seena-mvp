-- pgTAP tests for FR-S03: principal same-day operations dashboard.
begin;
select plan(19);

select public.provision_tenant('test-today-co', 'Today Co', 'owner@todayco.test');
select id as tenant_id from public.tenant where slug = 'test-today-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-today-other', 'Other Today Co', 'owner@othertodayco.test');
select id as other_tenant_id from public.tenant where slug = 'test-today-other' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'T2', 'Other Campus') returning id as campus2_id \gset

select gen_random_uuid() as teacher1 \gset
select gen_random_uuid() as teacher2 \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'teacher1', 't1@todayco.test', 'authenticated', 'authenticated', 'x'), (:'teacher2', 't2@todayco.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'teacher1', :'tenant_id', 'class_teacher', 'Ms Sana Malik'), (:'teacher2', :'tenant_id', 'class_teacher', 'Mr Bilal Ahmed');

select set_config('t.campus', :'campus_id', false), set_config('t.session', :'session_id', false), set_config('t.class', :'class1_id', false);
create temp table kid (sec text, n int, section_id uuid, student_id uuid, enrol_id uuid, primary key (sec, n));
grant all on kid to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
do $$
declare
  s text; i int; v_sec uuid; v_stu uuid;
begin
  foreach s in array array['A', 'B', 'C', 'D', 'E', 'F'] loop
    v_sec := public.create_section(current_setting('t.campus')::uuid, current_setting('t.session')::uuid, current_setting('t.class')::uuid, s, 20);
    for i in 1..2 loop
      v_stu := public.create_student(current_setting('t.campus')::uuid, 'Kid ' || s || i, '2015-01-01'::date, 'male');
      insert into kid values (s, i, v_sec, v_stu, public.enrol_student(v_sec, v_stu));
    end loop;
  end loop;
end $$;
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.assign_class_teacher((select section_id from kid where sec = 'E' and n = 1), :'teacher1'::uuid, current_date - 30);
select public.assign_class_teacher((select section_id from kid where sec = 'F' and n = 1), :'teacher2'::uuid, current_date - 30);
reset role;

select app.fn_karachi_today() as today \gset
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status)
select :'tenant_id', :'campus_id', :'session_id', section_id, enrol_id, :'today',
       case when (sec, n) in (('A', 1), ('B', 2), ('D', 1)) then 'absent'::public.student_attendance_status else 'present'::public.student_attendance_status end
  from kid where sec in ('A', 'B', 'C', 'D');

-- guardians: A1 and D1 are reachable, B2 has none
select public.fn_find_or_create_guardian(p_name_en => 'Father A1', p_phone_e164 => '+923001110001') as ga \gset
select public.fn_find_or_create_guardian(p_name_en => 'Father D1', p_phone_e164 => '+923001110004') as gd \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.link_guardian((select student_id from kid where sec = 'A' and n = 1), :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where sec = 'D' and n = 1), :'gd'::uuid, 'father'::public.guardian_relationship, true, true);
-- money: one 5,000 receipt stands; one 3,000 receipt is cancelled; a gateway payment is pending
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment((select enrol_id from kid where sec = 'A' and n = 1), 500000::bigint, 'cash'::public.fee_payment_mode, 's03-ok', :'today');
select public.record_payment((select enrol_id from kid where sec = 'A' and n = 2), 300000::bigint, 'cash'::public.fee_payment_mode, 's03-cancelled', :'today');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.reverse_ledger_entry((select id from public.fee_ledger where enrolment_id = (select enrol_id from kid where sec = 'A' and n = 2) and entry_type = 'payment'), 'receipt cancelled at the counter');
reset role;
insert into public.payment_intent (tenant_id, campus_id, enrolment_id, challan_id, gateway, gateway_ref, amount_paisa, expires_at, status)
select :'tenant_id', :'campus_id', k.enrol_id, c.id, 'jazzcash', 'JA-S03', 500000, now() + interval '20 minutes', 'pending'
  from kid k join public.fee_challan c on c.enrolment_id = k.enrol_id where k.sec = 'B' and k.n = 1;

select has_view('public', 'v_principal_today', 'v_principal_today exists');
select ok((select reloptions::text like '%security_invoker=true%' from pg_class where oid = 'public.v_principal_today'::regclass), 'it is security_invoker');
select ok((select pg_get_viewdef('public.v_principal_today'::regclass) not like '%agg_campus_day%'), 'AC: it never reads the aggregate layer');
select has_index('public', 'attendance_day', 'idx_attendance_campus_date', 'the covering attendance index exists');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select sections_marked || '/' || sections_total from public.v_principal_today where campus_id = :'campus_id'), '4/6', 'AC: "4/6 sections marked"');
select is((select count(*)::int from public.fn_unmarked_sections(:'campus_id'::uuid)), 2, 'AC: the 2 unmarked sections are listed');
select is((select string_agg(section_name || ':' || coalesce(class_teacher_name, '-'), ',' order by section_name) from public.fn_unmarked_sections(:'campus_id'::uuid)), 'E:Ms Sana Malik,F:Mr Bilal Ahmed', 'AC: with their class teachers by name');
select is((select absent_count from public.v_principal_today where campus_id = :'campus_id'), 3, 'three students are absent');
select is((select count(*)::int from public.fn_today_absentees(:'campus_id'::uuid)), 3, 'AC: the absentee list opens with all three');
select is((select string_agg(student_name || '=' || coalesce(guardian_phone, 'none'), ',' order by student_name) from public.fn_today_absentees(:'campus_id'::uuid)), 'Kid A1=+923001110001,Kid B2=none,Kid D1=+923001110004', 'AC: each row carries the guardian mobile (or none) for the WhatsApp action');
select ok((select gr_number is not null and section_name is not null from public.fn_today_absentees(:'campus_id'::uuid) limit 1), 'and the GR number and section');
select is((select collected_today_paisa from public.v_principal_today where campus_id = :'campus_id'), 500000::bigint, 'AC: collected today = the confirmed receipt only (the cancelled 3,000 drops out)');
select is((select pending_online_count from public.v_principal_today where campus_id = :'campus_id'), 1, 'AC: the online payment awaiting confirmation is counted separately, not as collected');

-- ── scope ─────────────────────────────────────────────────────────────────
select is((select count(*)::int from public.v_principal_today), 1, 'the principal sees only their campus');
select throws_ok(format($$ select * from public.fn_unmarked_sections(%L) $$, :'campus2_id'), 'FORBIDDEN', 'AC: asking about another campus is refused');
select throws_ok(format($$ select * from public.fn_today_absentees(%L) $$, :'campus2_id'), 'FORBIDDEN', 'for the absentee list too');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select * from public.fn_unmarked_sections(%L) $$, :'campus_id'), 'FORBIDDEN', 'a teacher cannot open the principal screens');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.v_principal_today where campus_id = :'campus_id'), 0, 'another school sees nothing, even claiming this campus');
select throws_ok(format($$ select * from public.fn_today_absentees(%L) $$, :'campus_id'), 'FORBIDDEN', 'nor calls the functions for it');
reset role;

select * from finish();
rollback;
