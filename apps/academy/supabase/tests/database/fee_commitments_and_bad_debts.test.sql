begin;
select plan(11);

select public.provision_tenant('test-fee-commit-co', 'Fee Commit Co', 'owner@feecommitco.test');
select id as tenant_id from public.tenant where slug = 'test-fee-commit-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-fee-commit-other', 'Fee Commit Other', 'owner@feecommitother.test');
select id as other_tenant from public.tenant where slug = 'test-fee-commit-other' \gset

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_student(:'campus_id'::uuid, 'Commit Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrolment_id \gset
select public.post_ledger_entry(:'enrolment_id'::uuid, 'charge', 500000::bigint, 'debit');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.add_fee_commitment(:'enrolment_id'::uuid, app.fn_karachi_today(), 300000::bigint, 'Father will pay after salary') as commitment_id \gset
select is((select count(*)::int from public.fee_commitment where id = :'commitment_id' and status = 'open'), 1,
  'the counter can record a promise to pay today');
select throws_ok(format('select public.add_fee_commitment(%L, %L::date, 1000)', :'enrolment_id', app.fn_karachi_today() - 1),
  'DATE_IN_PAST', 'a promise dated in the past is rejected');
select lives_ok(format('select public.set_fee_commitment_status(%L, ''kept'')', :'commitment_id'), 'a promise can be marked kept');
select throws_ok(format('select public.write_off_bad_debt(%L, 1000, ''Family left the city'')', :'enrolment_id'),
  'FORBIDDEN', 'the counter cannot write off a bad debt');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format('select public.add_fee_commitment(%L, %L::date, 1000)', :'enrolment_id', app.fn_karachi_today()),
  'FORBIDDEN', 'a teacher cannot record a promise');
select is((select count(*)::int from public.fee_commitment), 0, 'a teacher cannot read promises');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.add_fee_commitment(:'enrolment_id'::uuid, app.fn_karachi_today() + 7, 100000::bigint) as open_id \gset
select throws_ok(format('select public.write_off_bad_debt(%L, 600000, ''Family left the city'')', :'enrolment_id'),
  'MORE_THAN_OWED', 'a write-off larger than the balance is rejected');
select public.write_off_bad_debt(:'enrolment_id'::uuid, 200000::bigint, 'Family left the city');
select is(public.student_balance(:'enrolment_id'::uuid), 300000::bigint, 'the write-off reduces the balance through the fee ledger');
select is((select status::text from public.fee_commitment where id = :'open_id'), 'cancelled',
  'open promises are cancelled once a debt is written off');

select set_config('request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner')::text, true);
select throws_ok(format('select public.write_off_bad_debt(%L, 1000, ''Not my student'')', :'enrolment_id'),
  'ENROLMENT_NOT_FOUND', 'another school cannot write off this student''s fees');
select is((select count(*)::int from public.fee_bad_debt), 0, 'another school cannot see the bad debt register');

select * from finish();
rollback;
