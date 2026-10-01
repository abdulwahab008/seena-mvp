-- pgTAP tests for FR-S07: custom report builder.
begin;
select plan(41);

select public.provision_tenant('test-builder-co', 'Builder Co', 'owner@builder.test');
select id as tenant_id from public.tenant where slug = 'test-builder-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'BB', 'Builder Campus B') returning id as campus_b \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select public.provision_tenant('test-builder-other', 'Other Builder Co', 'owner@otherbuilder.test');
select id as other_tenant_id from public.tenant where slug = 'test-builder-other' \gset

insert into public.stream (tenant_id, code, name_en, board, applies_from_ordinal) values (:'tenant_id', 'PREMED', 'Pre-Medical', 'FBISE', 9) returning id as st_pm \gset
insert into public.stream (tenant_id, code, name_en, board, applies_from_ordinal) values (:'tenant_id', 'PREENG', 'Pre-Engineering', 'FBISE', 9) returning id as st_pe \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values (:'tenant_id', :'campus_a', :'session_id', :'class9', '9-A', 200, :'st_pm') returning id as sec_a \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values (:'tenant_id', :'campus_a', :'session_id', :'class9', '9-B', 200, :'st_pm') returning id as sec_b \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values (:'tenant_id', :'campus_a', :'session_id', :'class9', '9-C', 200, :'st_pe') returning id as sec_c \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values (:'tenant_id', :'campus_a', :'session_id', :'class10', '10-A', 100, null) returning id as sec_10 \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values (:'tenant_id', :'campus_b', :'session_id', :'class9', '9-X', 120, :'st_pm') returning id as sec_x \gset

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);
-- 400 Pre-Medical (200 in 9-A, 200 in 9-B), 100 Pre-Engineering, 50 in class 10, and 100 Pre-Medical on campus B
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', case when g > 650 then :'campus_b'::uuid else :'campus_a'::uuid end, 'BR' || lpad(g::text, 4, '0'), 'Builder Kid ' || g, '2011-01-01', 'male' from generate_series(1, 750) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select s.tenant_id, s.campus_id, :'session_id', s.id,
       case when n > 500 and n <= 550 then :'class10'::uuid else :'class9'::uuid end,
       case when n <= 200 then :'sec_a'::uuid when n <= 400 then :'sec_b'::uuid when n <= 500 then :'sec_c'::uuid when n <= 550 then :'sec_10'::uuid
            when n <= 650 then :'sec_c'::uuid else :'sec_x'::uuid end
  from (select st.*, row_number() over (order by gr_number) as n from public.student st where st.tenant_id = :'tenant_id') s
 where not (n > 550 and n <= 650);   -- 551..650 deliberately not enrolled
insert into public.guardian (tenant_id, name_en, cnic, phone_e164) values (:'tenant_id', 'Guardian One', '35202-1234567-1', '+923001234567') returning id as g1 \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) select tenant_id, id, :'g1', 'father', true, true from public.student where tenant_id = :'tenant_id' and gr_number = 'BR0001';

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_b_uid \gset
select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@builder.test', 'authenticated', 'authenticated', 'x'), (:'prin_b_uid', 'pb@builder.test', 'authenticated', 'authenticated', 'x'), (:'acct_uid', 'a@builder.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Builder Owner'), (:'prin_b_uid', :'tenant_id', 'principal', 'Principal B'), (:'acct_uid', :'tenant_id', 'accountant', 'Accountant');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_b_uid', :'tenant_id', :'campus_b'), (:'acct_uid', :'tenant_id', :'campus_a');

select is((select jsonb_array_length(allowed_columns_json) from public.report_dataset where dataset_key = 'ds_student_enrolment'), 28, 'the Student Enrolment dataset exposes 28 columns');
select is((select relkind::text from pg_class where oid = 'public.v_ds_student_enrolment'::regclass), 'v', 'its base view exists');
select is((select count(*)::int from pg_class where oid in ('public.v_ds_student_enrolment'::regclass, 'public.v_ds_fee_ledger'::regclass, 'public.v_ds_exam_result'::regclass) and reloptions::text like '%security_invoker=true%'), 3, 'all three base views are security_invoker');
select is((select prosecdef from pg_proc where oid = 'public.fn_run_saved_report(uuid,int,int)'::regprocedure), false, 'the runner is SECURITY INVOKER, never definer');
select is((select prosecdef from pg_proc where oid = 'app.fn_report_plan(text,jsonb)'::regprocedure), false, 'and so is the planner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select is((select count(*)::int from public.fn_report_columns('ds_student_enrolment')), 28, 'the owner''s picker shows all 28 columns');
select is((select count(*)::int from public.fn_report_datasets()), 3, 'and all three datasets');

-- ── AC1: select columns, filter class = 9 AND group = Pre-Medical, group by section ──
select public.save_report('Pre-Med by section', 'ds_student_enrolment',
  '{"columns":["gr_number","student_name","section_name"],"filters":[{"column":"class_code","op":"eq","value":"9"},{"column":"group_name","op":"eq","value":"Pre-Medical"}],"group_by":["section_name"]}'::jsonb, true) as r_group \gset
select public.save_report('Pre-Med list', 'ds_student_enrolment',
  '{"columns":["gr_number","student_name","section_name","class_name","group_name"],"filters":[{"column":"class_code","op":"eq","value":"9"},{"column":"group_name","op":"eq","value":"Pre-Medical"}],"order_by":[{"column":"gr_number"}]}'::jsonb, true) as r_list \gset
select is((select jsonb_array_length(public.fn_run_saved_report(:'r_group'::uuid) -> 'rows')), 3, 'AC1: grouped by section: 9-A, 9-B (campus A) and 9-X (campus B) for the owner');
select is((select (public.fn_run_saved_report(:'r_group'::uuid) -> 'rows' -> 0 ->> 'row_count')::int), 200, 'AC1: with the row count per section');
select is((select jsonb_array_length(public.fn_run_saved_report(:'r_list'::uuid) -> 'rows')), 100, 'AC1: the preview is the first 100 rows');
select is((public.fn_run_saved_report(:'r_list'::uuid) ->> 'total_rows')::int, 500, 'AC1: out of 500 matching rows (400 + 100)');
select ok((public.fn_run_saved_report(:'r_list'::uuid) ->> 'elapsed_ms')::numeric < 3000, 'AC1: rendered in under 3 seconds');
select is((public.fn_run_saved_report(:'r_list'::uuid, 2, 100) -> 'rows' -> 0 ->> 'gr_number'), 'BR0101', 'page 2 continues from row 101');
select is((select jsonb_array_length(public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"class_code","op":"eq","value":"10"}]}'::jsonb) -> 'rows')), 50, 'the live preview of an unsaved definition runs the same plan');

-- ── safety: values are bind parameters, identifiers are whitelisted ───────
select is((select jsonb_array_length(public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"class_code","op":"eq","value":"9'' or ''1''=''1"}]}'::jsonb) -> 'rows')), 0, 'a quote in a filter value is just a value: no rows, no error');
select throws_ok($$ select public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number\"; drop table public.student; --"]}'::jsonb) $$, 'column_not_permitted', 'a hand-made column name is refused, never interpolated');
select throws_ok($$ select public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"class_code","op":"; drop table x","value":"9"}]}'::jsonb) $$, 'DEFINITION_INVALID', 'an unknown operator is refused');
select throws_ok($$ select public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"roll_no","op":"eq","value":"abc"}]}'::jsonb) $$, '22P02', null, 'a value of the wrong type fails its cast instead of reaching SQL');
select is((select jsonb_array_length(public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"student_name","op":"contains","value":"%"}]}'::jsonb) -> 'rows')), 0, 'a % in a contains filter matches a literal %, not everything');
select is((select jsonb_array_length(public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"gr_number","op":"in","value":["BR0001","BR0002","BR9999"]}]}'::jsonb) -> 'rows')), 2, 'an in-list works');
select throws_ok($$ select public.fn_preview_report('ds_nope', '{"columns":["x"]}'::jsonb) $$, 'DATASET_NOT_AVAILABLE', 'an unknown dataset is refused');
select throws_ok(format($$ insert into public.saved_report (tenant_id, owner_user_id, name, dataset_key, definition_json) values (%L, %L, 'x', 'ds_student_enrolment', '{}') $$, :'tenant_id', :'owner_uid'), '42501', null, 'a client cannot insert a saved report directly: only save_report validates');

-- ── AC2: a shared report run by another campus' Principal sees only that campus ──
select public.save_report('Private to owner', 'ds_student_enrolment', '{"columns":["gr_number"]}'::jsonb, false) as r_private \gset
select definition_json as def_before from public.saved_report where id = :'r_list' \gset
select set_config('request.jwt.claims', json_build_object('sub', :'prin_b_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((public.fn_run_saved_report(:'r_list'::uuid) ->> 'total_rows')::int, 100, 'AC2: the campus-B Principal gets only campus B''s 100 Pre-Medical students');
select is((select count(*)::int from jsonb_array_elements(public.fn_run_saved_report(:'r_list'::uuid, 1, 1000) -> 'rows') x where x ->> 'gr_number' < 'BR0651'), 0, 'AC2: none of campus A''s students appear');
select is((select jsonb_array_length(public.fn_run_saved_report(:'r_group'::uuid) -> 'rows')), 1, 'AC2: the grouped report shows only 9-X');
select is((select count(*)::int from public.saved_report where id = :'r_private'), 0, 'an unshared report is invisible to a colleague');
select throws_ok(format($$ select public.fn_run_saved_report(%L) $$, :'r_private'), 'REPORT_NOT_FOUND', 'and cannot be run by them');
reset role;
select is((select definition_json from public.saved_report where id = :'r_list') = :'def_before'::jsonb, true, 'AC2: running it changed nothing in the saved definition');

-- ── AC3: guardian CNIC for a role that may not see it ─────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.fn_report_columns('ds_student_enrolment') where key = 'guardian_cnic'), 0, 'AC3: guardian CNIC is absent from the accountant''s column picker');
select is((select count(*)::int from public.fn_report_columns('ds_student_enrolment')), 24, 'AC3: only the four personal-data columns are hidden (24 of 28 remain)');
select throws_ok($$ select public.save_report('Sneaky', 'ds_student_enrolment', '{"columns":["gr_number","guardian_cnic"]}'::jsonb, false) $$, 'column_not_permitted', 'AC3: a definition naming guardian CNIC is rejected with column_not_permitted');
select throws_ok($$ select public.fn_preview_report('ds_student_enrolment', '{"columns":["gr_number"],"filters":[{"column":"guardian_cnic","op":"eq","value":"35202-1234567-1"}]}'::jsonb) $$, 'column_not_permitted', 'AC3: and so is a filter on it (it would leak the value by probing)');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select public.save_report('With CNIC', 'ds_student_enrolment', '{"columns":["gr_number","guardian_cnic"],"filters":[{"column":"gr_number","op":"eq","value":"BR0001"}]}'::jsonb, true) as r_cnic \gset
select is((public.fn_run_saved_report(:'r_cnic'::uuid) -> 'rows' -> 0 ->> 'guardian_cnic'), '35202-1234567-1', 'the owner, who may, sees the CNIC');
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select throws_ok(format($$ select public.fn_run_saved_report(%L) $$, :'r_cnic'), 'column_not_permitted', 'AC3: a shared report containing it is refused when the accountant runs it');

-- ── AC4: more than the async threshold -> capped preview with a notice ────
reset role;
update public.report_dataset set async_threshold_rows = 300, max_preview_rows = 150 where dataset_key = 'ds_student_enrolment';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b'))::text, true);
select is((public.fn_run_saved_report(:'r_list'::uuid, 1, 1000) ->> 'capped')::boolean, true, 'AC4: a definition over the threshold is capped');
select is((select jsonb_array_length(public.fn_run_saved_report(:'r_list'::uuid, 1, 1000) -> 'rows')), 150, 'AC4: the preview returns the cap, not everything');
select ok((public.fn_run_saved_report(:'r_list'::uuid) ->> 'notice') ilike '%asynchronous export%', 'AC4: with a notice pointing to the asynchronous export');
select is((select jsonb_array_length(public.fn_run_saved_report(:'r_list'::uuid, 2, 100) -> 'rows')), 50, 'AC4: paging stops at the cap (page 2 holds the remaining 50 of 150)');
select is((public.fn_run_saved_report(:'r_group'::uuid) ->> 'capped')::boolean, false, 'a small result is not capped');

-- ── asynchronous export carries the report, scoped to the requester ───────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_b_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select (public.request_saved_report_export(:'r_list'::uuid) ->> 'job_id')::uuid as job_id \gset
reset role;
update public.report_export_job set status = 'running', started_at = now() where id = :'job_id';
select is((select jsonb_array_length(public.export_job_page(:'job_id'::uuid, 0, 5000))), 100, 'the export runs the saved definition for the requester: 100 campus-B rows, uncapped by the screen preview');
select is((select jsonb_array_length(app.fn_job_columns('ds_student_enrolment', (select params from public.report_export_job where id = :'job_id'), (select claims from public.report_export_job where id = :'job_id'), '[]'::jsonb))), 5, 'and the export uses the report''s own five columns');

select * from finish();
rollback;
