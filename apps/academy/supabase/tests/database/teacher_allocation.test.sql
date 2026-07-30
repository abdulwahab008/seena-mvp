-- pgTAP tests for FR-E08 (class teacher allocation) and FR-E09 (subject
-- teacher allocation).
begin;
select plan(10);

select public.provision_tenant('test-teacher-alloc-co', 'Teacher Alloc Co', 'owner@teacheralloc.test');
select id as tenant_id from public.tenant where slug = 'test-teacher-alloc-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class6_id from public.class_level where tenant_id = :'tenant_id' and code = '6' \gset
select id as class7_id from public.class_level where tenant_id = :'tenant_id' and code = '7' \gset

-- app_user rows require an auth.users row via FK — seeded directly, as
-- superuser (like provision_tenant above), before switching to
-- authenticated: neither auth.users nor a direct app_user insert is
-- reachable by the authenticated role.
select gen_random_uuid() as bilal_id \gset
select gen_random_uuid() as sana_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'bilal_id', 'bilal@teacheralloc.test', 'x', now(), 'authenticated', 'authenticated'),
       (:'sana_id', 'sana@teacheralloc.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'bilal_id', :'tenant_id', 'class_teacher', 'Mr. Bilal'),
       (:'sana_id', :'tenant_id', 'class_teacher', 'Ms. Sana');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_name => 'B', p_capacity => 40) as section_6b_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class7_id', p_name => 'A', p_capacity => 40) as section_7a_id \gset

-- ── E08: assignment, auto-close predecessor, no gap/overlap ───────────

select public.assign_class_teacher(:'section_6b_id'::uuid, :'bilal_id'::uuid, '2026-08-01'::date) as bilal_alloc \gset
select is(
  (:'bilal_alloc'::jsonb ->> 'warning'),
  null,
  'Mr. Bilal''s first class-teacher assignment carries no warning'
);

select public.assign_class_teacher(:'section_6b_id'::uuid, :'sana_id'::uuid, '2026-11-15'::date) as sana_alloc \gset
select is(
  (select effective_to from public.section_class_teacher where section_id = :'section_6b_id' and staff_id = :'bilal_id'),
  '2026-11-14'::date,
  'assigning Ms. Sana from 2026-11-15 auto-closes Mr. Bilal''s range the day before'
);
select is(
  (select validity from public.section_class_teacher where section_id = :'section_6b_id' and staff_id = :'bilal_id')
  && (select validity from public.section_class_teacher where section_id = :'section_6b_id' and staff_id = :'sana_id'),
  false,
  'the two ranges do not overlap'
);

-- ── E08: a report card signed in the Bilal range still resolves to Bilal ─

select is(
  (select staff_id from public.section_class_teacher
    where section_id = :'section_6b_id' and validity @> '2026-09-20'::date),
  :'bilal_id',
  'a date inside Mr. Bilal''s range (e.g. a report-card approval date) resolves to him, regardless of who holds the post now'
);

-- ── E08: direct overlapping insert is rejected by the exclusion constraint ─
-- section_class_teacher has no INSERT policy for authenticated at all (every
-- write goes through assign_class_teacher), so this specifically isolates
-- the constraint's own protection, run as superuser like the GR-number and
-- roll-number immutability tests before it.

reset role;
select throws_ok(
  format(
    $$ insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from, effective_to)
       values (%L, %L, %L, %L, %L, '2026-09-01', '2026-09-30') $$,
    :'tenant_id', :'campus_id', :'session_id', :'section_6b_id', :'bilal_id'
  ),
  'conflicting key value violates exclusion constraint "ex_class_teacher_no_overlap"',
  'a direct insert overlapping Ms. Sana''s open-ended range is rejected'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── E08: dual class-teacher is a warning, not a block ──────────────────

select public.assign_class_teacher(:'section_7a_id'::uuid, :'sana_id'::uuid, '2026-08-01'::date) as sana_dual_alloc \gset
select is(
  (:'sana_dual_alloc'::jsonb ->> 'warning'),
  'DUAL_CLASS_TEACHER',
  'Ms. Sana holding both 6-B and 7-A in the same session is flagged with a warning'
);
select is(
  (select count(*)::int from public.section_class_teacher where staff_id = :'sana_id' and effective_to is null),
  2,
  'the dual assignment is permitted — she now holds two open-ended class-teacher rows'
);

-- ── E09: PRIMARY overlap excluded, ASSISTANT does not conflict ────────

select public.create_subject('PHY', 'Physics', 'طبیعیات') as physics_id \gset
select public.assign_subject_teacher(:'section_6b_id'::uuid, :'physics_id'::uuid, :'bilal_id'::uuid, '2026-08-01'::date) as primary_alloc_id \gset

reset role;
select throws_ok(
  format(
    $$ insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, role, effective_from)
       values (%L, %L, %L, %L, %L, %L, 'primary', '2026-09-01') $$,
    :'tenant_id', :'campus_id', :'session_id', :'section_6b_id', :'physics_id', :'sana_id'
  ),
  'conflicting key value violates exclusion constraint "ex_subject_teacher_no_overlap"',
  'a second overlapping PRIMARY for the same section+subject is rejected until the first is closed'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.assign_subject_teacher(:'section_6b_id'::uuid, :'physics_id'::uuid, :'sana_id'::uuid, '2026-08-01'::date, 'assistant') as assistant_alloc_id \gset
select is(
  (select count(*)::int from public.section_subject_teacher where section_id = :'section_6b_id' and subject_id = :'physics_id' and effective_to is null),
  2,
  'an assistant alongside the primary is permitted — co-teaching is two rows, not a conflict'
);

-- ── E09: v_unallocated_section_subject reports what still needs a teacher ─

select public.create_subject('CHEM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_subject_id => :'physics_id', p_weekly_periods => 6::smallint);
select public.upsert_class_subject(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class6_id', p_subject_id => :'chem_id', p_weekly_periods => 6::smallint);
select is(
  (select subject_id from public.v_unallocated_section_subject where section_id = :'section_6b_id'),
  :'chem_id',
  'Physics has a primary teacher and drops off the unallocated list; Chemistry (unallocated) remains'
);

select * from finish();
rollback;
