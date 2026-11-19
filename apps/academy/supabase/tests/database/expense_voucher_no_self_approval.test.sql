-- A voucher's raiser cannot decide it below Owner; an Owner still can.
begin;
select plan(4);

select public.provision_tenant('test-expense-self', 'Expense Self Co', 'owner@expself.test');
select id as tenant_id from public.tenant where slug = 'test-expense-self' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as head_util from public.expense_head where tenant_id = :'tenant_id' and code = 'UTILITIES' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@expself.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Self Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@expself.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'principal_uid', :'tenant_id', 'principal', 'Self Principal');

set local role authenticated;

-- The Principal raises a PKR 150,000 voucher, which the bands route to the Principal.
select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text, true);
select public.submit_expense_voucher(:'campus_a'::uuid, :'head_util'::uuid, 'K-Electric', 15000000::bigint, current_date, null, 'Electricity', null, null) as v1 \gset
select (:'v1'::jsonb ->> 'voucher_id') as v1_id \gset

select throws_ok(
  format($$ select public.decide_expense_voucher(%L, 'approved') $$, :'v1_id'),
  '42501', 'SELF_APPROVAL_NOT_ALLOWED',
  'a Principal cannot approve a voucher they raised'
);

-- The Owner decides it instead.
select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text, true);
select is(
  (public.decide_expense_voucher(:'v1_id'::uuid, 'approved')) ->> 'status',
  'approved',
  'someone other than the raiser can approve it'
);

-- An Owner raising and approving their own voucher is still allowed.
select public.submit_expense_voucher(:'campus_a'::uuid, :'head_util'::uuid, 'K-Electric', 15000000::bigint, current_date, null, 'Electricity 2', null, null) as v2 \gset
select (:'v2'::jsonb ->> 'voucher_id') as v2_id \gset
select is(:'v2'::jsonb ->> 'status', 'pending_approval', 'the Owner''s own voucher waits in the queue');
select is(
  (public.decide_expense_voucher(:'v2_id'::uuid, 'approved')) ->> 'status',
  'approved',
  'an Owner can still decide a voucher they raised'
);

select * from finish();
rollback;
