-- pgTAP tests for FR-K19: bank statement upload and parsing.
begin;
select plan(22);

select public.provision_tenant('test-bank-upload-co', 'Bank Upload Co', 'owner@bankuploadco.test');
select id as tenant_id from public.tenant where slug = 'test-bank-upload-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-bank-upload-other', 'Other Bank Co', 'owner@otherbankco.test');
select id as other_tenant_id from public.tenant where slug = 'test-bank-upload-other' \gset

insert into public.campus_bank_account (campus_id, bank_name, title, account_no, iban)
values (:'campus_id', 'HBL', 'Bank Upload Co Fees', '1234567890', 'PK36HABB0000001234567890') returning id as acct_id \gset

select gen_random_uuid() as acct_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values (:'acct_uid', 'ali@bankuploadco.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'acct_uid', :'tenant_id', 'accountant', 'Ali Accountant');

select has_table('public', 'bank_statement_line', 'bank_statement_line exists');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.bank_mapping_profile'::regclass, 'public.bank_statement_import'::regclass, 'public.bank_statement_line'::regclass)), 'RLS on all three tables');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── profiles ──────────────────────────────────────────────────────────────
select public.create_bank_mapping_profile('HBL_SCROLL_V2', 'csv', '{"txn_date":"Date","challan_ref":"Customer Ref","bank_ref":"Txn ID","amount":"Credit"}'::jsonb, 'DD/MM/YYYY', 'credit_positive') as profile_id \gset
select isnt(:'profile_id'::uuid, null::uuid, 'an accountant creates a mapping profile');
select throws_ok($$ select public.create_bank_mapping_profile('BAD', 'csv', '{"txn_date":"Date"}'::jsonb, 'DD/MM/YYYY', 'credit_positive') $$, 'INVALID_MAPPING_PROFILE', 'a profile missing required columns is rejected');
select throws_ok($$ select public.create_bank_mapping_profile('BAD2', 'csv', '{"txn_date":"D","challan_ref":"C","bank_ref":"R","amount":"A"}'::jsonb, 'DD/MM/YYYY', 'separate_columns') $$, 'INVALID_MAPPING_PROFILE', 'separate-column profiles need debit and credit');
select lives_ok(format($$ select public.assign_bank_mapping_profile(%L, %L) $$, :'acct_id', :'profile_id'), 'the profile is assigned to the account');

-- ── upload ────────────────────────────────────────────────────────────────
select public.start_bank_statement_import(:'acct_id'::uuid, repeat('a', 64), 'scroll.csv', 't/scroll.csv') as import_id \gset
select is((select status from public.bank_statement_import where id = :'import_id'), 'uploaded', 'the import starts uploaded');
select throws_ok(format($$ select public.start_bank_statement_import(%L, %L, 'scroll.csv', 'x') $$, :'acct_id', repeat('a', 64)), '23505', 'duplicate file (sha256 match, imported ' || to_char(now(), 'DD-MM-YYYY') || ' by Ali Accountant)', 'AC: the same file is rejected, naming when and who imported it');
select throws_ok(format($$ select public.start_bank_statement_import(%L, %L, 'x.csv', 'x') $$, :'acct_id', 'not-a-hash'), '23514', null, 'a malformed hash is refused by the table constraint');

select public.add_bank_statement_lines(:'import_id'::uuid,
  (select jsonb_agg(jsonb_build_object('line_no', n + 1, 'txn_date', '2026-08-12', 'challan_ref', lpad(n::text, 12, '0'), 'amount_paisa', 850000, 'bank_ref', 'TX' || n, 'raw_line', 'row ' || n))
     from generate_series(1, 308) n)) as first_chunk \gset
select is((:'first_chunk'::jsonb ->> 'parsed')::int, 308, 'AC: 308 rows parsed in the first chunk');
select public.add_bank_statement_lines(:'import_id'::uuid,
  '[{"line_no":400,"raw_line":"bad,row,1","error":"BAD_AMOUNT"},{"line_no":401,"raw_line":"bad,row,2","error":"BAD_DATE"},{"line_no":402,"raw_line":"bad,row,3","error":"MISSING_OR_BAD_CHALLAN_REF"},{"line_no":403,"raw_line":"bad,row,4","error":"BAD_AMOUNT"}]'::jsonb, true) as second_chunk \gset
select is((:'second_chunk'::jsonb ->> 'failed')::int, 4, 'AC: the 4 unparseable rows are kept as parse_error');
select is((select row_count || '/' || parsed_count || '/' || failed_count from public.bank_statement_import where id = :'import_id'), '312/308/4', 'the import shows the row, parsed and failed counts');
select is((select status from public.bank_statement_import where id = :'import_id'), 'parsed', 'completing the last chunk marks it parsed');
select is((select raw_line from public.bank_statement_line where import_id = :'import_id' and line_no = 402), 'bad,row,3', 'AC: the raw line text is preserved for a failed row');
select throws_ok(format($$ select public.add_bank_statement_lines(%L, '[]'::jsonb) $$, :'import_id'), 'IMPORT_ALREADY_PARSED', 'a parsed import cannot be appended to');
select throws_ok(format($$ select public.add_bank_statement_lines(%L, (select jsonb_agg(jsonb_build_object('line_no', n, 'raw_line', 'x', 'error', 'E')) from generate_series(1, 1001) n)) $$, (select public.start_bank_statement_import(:'acct_id'::uuid, repeat('b', 64), 'big.csv', 'x'))), 'LINES_MUST_BE_AN_ARRAY_OF_AT_MOST_1000', 'a chunk over 1000 rows is refused');

-- ── authorization and isolation ───────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.start_bank_statement_import(%L, %L, 'x.csv', 'x') $$, :'acct_id', repeat('c', 64)), 'FORBIDDEN', 'a teacher cannot upload statements');
select is((select count(*)::int from public.bank_statement_line), 0, 'nor read statement lines');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.bank_statement_import), 0, 'another school''s owner sees no imports');
select throws_ok(format($$ select public.start_bank_statement_import(%L, %L, 'x.csv', 'x') $$, :'acct_id', repeat('d', 64)), 'BANK_ACCOUNT_NOT_FOUND', 'and cannot upload against this school''s bank account');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(gen_random_uuid()))::text, true);
select throws_ok(format($$ select public.start_bank_statement_import(%L, %L, 'x.csv', 'x') $$, :'acct_id', repeat('e', 64)), 'FORBIDDEN', 'an accountant of a different campus is refused');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.bank_statement_line where import_id = :'import_id'), 312, 'the campus accountant reads all 312 lines');
reset role;

select * from finish();
rollback;
