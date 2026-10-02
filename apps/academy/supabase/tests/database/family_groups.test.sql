-- pgTAP tests for FR-C08: sibling family groups.
begin;
select plan(7);

select public.provision_tenant('test-family-co', 'Family Co', 'owner@familyco.test');
select id as tenant_id from public.tenant where slug = 'test-family-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.fn_find_or_create_guardian(p_name_en => 'Common Father', p_cnic => '3520212340001') as father_id \gset

-- Three siblings, admitted in order (eldest first), each linked to the
-- same father so fn_suggest_family_group can find them by CNIC.
select public.create_student(:'campus_id'::uuid, 'Eldest Child', '2012-01-01'::date, 'male') as eldest_id \gset
select public.link_guardian(:'eldest_id'::uuid, :'father_id'::uuid, 'father', true, true);
select public.create_student(:'campus_id'::uuid, 'Middle Child', '2014-01-01'::date, 'female') as middle_id \gset
select public.link_guardian(:'middle_id'::uuid, :'father_id'::uuid, 'father', true, true);
select public.create_student(:'campus_id'::uuid, 'Youngest Child', '2016-01-01'::date, 'male') as youngest_id \gset
select public.link_guardian(:'youngest_id'::uuid, :'father_id'::uuid, 'father', true, true);

-- ── fn_suggest_family_group finds all 3 by father CNIC ─────────────

select is(
  (select count(*)::int from public.fn_suggest_family_group('4210198760002')),
  0,
  'a CNIC that belongs to nobody in the tenant matches nothing'
);
select is(
  (select count(*)::int from public.fn_suggest_family_group('3520212340001')),
  3,
  'searching by the father''s CNIC (raw digits) surfaces all 3 linked children'
);

-- ── link_family_group: one action links all three ──────────────────

select public.link_family_group(array[:'eldest_id', :'middle_id', :'youngest_id']::uuid[], '3520212340001') as group_id \gset
select is(
  (select count(distinct family_group_id)::int from public.student where id in (:'eldest_id', :'middle_id', :'youngest_id')),
  1,
  'all three siblings now share exactly one family_group_id'
);

-- ── v_sibling_rank: by ascending admission (created_at), active only ──

-- row_number() returns bigint, hence the ::bigint literals below.
select is(
  (select sibling_rank from public.v_sibling_rank where student_id = :'eldest_id'),
  1::bigint,
  'the eldest (first admitted) is sibling rank 1'
);
select is(
  (select sibling_rank from public.v_sibling_rank where student_id = :'youngest_id'),
  3::bigint,
  'the youngest (last admitted) is sibling rank 3'
);

-- Eldest graduates: ranks recompute over active students only, no stored
-- column to update by hand. student has no UPDATE policy for authenticated
-- (writes are function-gated, and there's no "graduate a student" function
-- yet), so this direct update has to run as superuser.
reset role;
update public.student set status = 'graduated' where id = :'eldest_id';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.v_sibling_rank where student_id = :'eldest_id'),
  0,
  'the graduated eldest drops out of the active sibling ranking entirely'
);
select is(
  (select sibling_rank from public.v_sibling_rank where student_id = :'middle_id'),
  1::bigint,
  'the middle child becomes rank 1 among active siblings the moment the eldest graduates'
);

select * from finish();
rollback;
