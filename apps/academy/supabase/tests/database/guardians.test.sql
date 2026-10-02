-- pgTAP tests for FR-C09 (multiple guardians per student) and FR-C10
-- (shared guardian dedup).
begin;
select plan(10);

select public.provision_tenant('test-guardian-co', 'Guardian Co', 'owner@guardianco.test');
select id as tenant_id from public.tenant where slug = 'test-guardian-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_student(:'campus_id'::uuid, 'Hassan Tariq', '2015-01-01'::date, 'male') as hassan_id \gset

-- ── CNIC normalization + dedup (C10) ──────────────────────────────────

select public.fn_find_or_create_guardian(p_name_en => 'Tariq Mehmood', p_cnic => '3520212345678') as father_id \gset
select is(
  (select cnic from public.guardian where id = :'father_id'),
  '35202-1234567-8',
  'a CNIC typed as 13 raw digits is normalised to dashed format on save'
);

select public.fn_find_or_create_guardian(p_name_en => 'Tariq Mehmood Duplicate Attempt', p_cnic => '35202-1234567-8') as father_id_again \gset
select is(
  :'father_id_again'::uuid,
  :'father_id'::uuid,
  'entering the same CNIC again returns the existing guardian instead of creating a duplicate'
);

-- Two CNIC-less guardians are both permitted (partial unique index).
select public.fn_find_or_create_guardian(p_name_en => 'Unknown Guardian One') as no_cnic_1 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Unknown Guardian Two') as no_cnic_2 \gset
select isnt(:'no_cnic_1'::uuid, :'no_cnic_2'::uuid, 'two guardians with no CNIC are both created, not collapsed into one');

-- ── linking, billing recipient requirement (C09) ───────────────────────

select throws_ok(
  format('select public.link_guardian(%L, %L, ''father'', true, false)', :'hassan_id', :'father_id'),
  'At least one guardian must receive fee notices',
  'linking the only guardian on a student with receives_billing=false is rejected at commit'
);

select public.link_guardian(:'hassan_id'::uuid, :'father_id'::uuid, 'father', true, true);
select is(
  (select is_primary from public.student_guardian where student_id = :'hassan_id' and guardian_id = :'father_id'),
  true,
  'the father is linked as primary once billing is satisfied'
);

select public.fn_find_or_create_guardian(p_name_en => 'Sana Tariq', p_cnic => '3520298765432') as mother_id \gset
select throws_ok(
  format('select public.link_guardian(%L, %L, ''mother'', true, true)', :'hassan_id', :'mother_id'),
  'PRIMARY_GUARDIAN_EXISTS',
  'marking a second guardian primary is rejected while the father is still the primary'
);
select public.link_guardian(:'hassan_id'::uuid, :'mother_id'::uuid, 'mother', false, true);

-- ── may_collect_child ───────────────────────────────────────────────

select public.fn_find_or_create_guardian(p_name_en => 'Uncle Bilal') as uncle_id \gset
select public.link_guardian(:'hassan_id'::uuid, :'uncle_id'::uuid, 'uncle', false, false, true, false);
select is(
  (select may_collect_child from public.student_guardian where student_id = :'hassan_id' and guardian_id = :'uncle_id'),
  false,
  'the uncle is linked with may_collect_child=false — a gate pass system would refuse his pickup'
);

-- ── unlink end-dates rather than deletes ───────────────────────────

select public.unlink_guardian(:'hassan_id'::uuid, :'uncle_id'::uuid);
select is(
  (select count(*)::int from public.student_guardian where student_id = :'hassan_id' and guardian_id = :'uncle_id'),
  1,
  'the uncle''s link row still exists after unlinking — it is end-dated, not deleted'
);
select isnt(
  (select to_date from public.student_guardian where student_id = :'hassan_id' and guardian_id = :'uncle_id'),
  null,
  'the unlinked row now carries a to_date'
);

-- ── v_guardian_children: campus-scoped ─────────────────────────────

select is(
  (select count(*)::int from public.v_guardian_children where guardian_id = :'father_id'),
  1,
  'the father sees exactly Hassan in his children list (this campus is the only one in scope)'
);

select * from finish();
rollback;
