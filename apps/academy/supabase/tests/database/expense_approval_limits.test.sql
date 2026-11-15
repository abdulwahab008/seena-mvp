-- pgTAP: an owner moves the expense approval cut-offs and the three bands stay contiguous.
begin;
select plan(5);

select public.provision_tenant('test-approval-limits', 'Limits Co', 'owner@limits.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.set_expense_approval_limits(%L, 1000000, 5000000)', :'campus_id'), 'FORBIDDEN', 'a principal cannot change the approval limits');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.set_expense_approval_limits(%L, 5000000, 5000000)', :'campus_id'), 'THRESHOLD_RANGE_INVALID', 'the principal limit must be above the self-approval limit');
select lives_ok(format('select public.set_expense_approval_limits(%L, 1000000, 5000000)', :'campus_id'), 'the owner sets Rs 10,000 and Rs 50,000');
select is(
  (select string_agg(min_amount_paisa || '-' || coalesce(max_amount_paisa::text, 'up') || ':' || coalesce(required_role::text, 'self'), ' ' order by min_amount_paisa)
     from public.approval_threshold where campus_id = :'campus_id'::uuid),
  '0-1000000:self 1000001-5000000:principal 5000001-up:owner',
  'the three bands are rewritten end to end');
select lives_ok(format('select public.set_expense_approval_limits(%L, 2500000, 20000000)', :'campus_id'), 'and can change them again without an overlap error');

select * from finish();
rollback;
