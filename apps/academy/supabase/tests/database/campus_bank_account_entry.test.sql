-- pgTAP tests for adding the bank account fee collections land in.
begin;
select plan(6);

select public.provision_tenant('test-bank-acct-entry', 'Bank Acct Co', 'owner@bankacct.test');
select id as tenant_id from public.tenant where slug = 'test-bank-acct-entry' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-bank-acct-other', 'Other Acct Co', 'owner@otheracct.test');
select c.id as other_campus from public.campus c join public.tenant t on t.id = c.tenant_id where t.slug = 'test-bank-acct-other' \gset

select gen_random_uuid() as acct_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'acct_uid', 'a@bankacct.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@bankacct.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'acct_uid', :'tenant_id', 'accountant', 'Accountant'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'acct_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok(public.add_campus_bank_account(:'campus_id', 'HBL', 'Fees Collection', ' 0012345 ') is not null, 'an accountant adds a bank account');
select is((select account_no from public.campus_bank_account where campus_id = :'campus_id'), '0012345', 'the account shows up for the accountant, trimmed');
select throws_ok(format($$ select public.add_campus_bank_account(%L, 'HBL', 'Again', '0012345') $$, :'campus_id'), 'BANK_ACCOUNT_EXISTS', 'the same account number twice is refused');
select throws_ok(format($$ select public.add_campus_bank_account(%L, 'HBL', ' ', '99') $$, :'campus_id'), 'BANK_ACCOUNT_FIELDS_REQUIRED', 'every field is needed');
select throws_ok(format($$ select public.add_campus_bank_account(%L, 'HBL', 'Theirs', '77') $$, :'other_campus'), 'CAMPUS_NOT_FOUND', 'not on another school''s campus');

select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.add_campus_bank_account(%L, 'HBL', 'Mine', '55') $$, :'campus_id'), 'FORBIDDEN', 'a teacher cannot add one');

select * from finish();
rollback;
