-- pgTAP tests for FR-F01 (bell template definition).
begin;
select plan(20);

select public.provision_tenant('test-bell-co', 'Bell Co', 'owner@bellco.test');
select id as tenant_id from public.tenant where slug = 'test-bell-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-bell-other', 'Other Bell Co', 'owner@otherbell.test');
select id as other_tenant_id from public.tenant where slug = 'test-bell-other' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@bellco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@bellco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'A Teacher');

-- A second campus in the same tenant, so RLS's campus_ids scoping (not
-- just tenant_id) can be exercised.
insert into public.campus (tenant_id, name, code)
values (:'tenant_id', 'Second Campus', 'C2')
returning id as campus2_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── create_bell_template: the AC's own worked example ───────────────────
-- assembly 07:45-08:00, 8x40min teaching periods, a break 10:40-11:00.

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular Morning',
  jsonb_build_array(
    jsonb_build_object('kind', 'ASSEMBLY', 'start_time', '07:45', 'end_time', '08:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:40', 'end_time', '09:20'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:20', 'end_time', '10:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:00', 'end_time', '10:40'),
    jsonb_build_object('kind', 'BREAK', 'start_time', '10:40', 'end_time', '11:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '11:00', 'end_time', '11:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '11:40', 'end_time', '12:20'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '12:20', 'end_time', '13:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '13:00', 'end_time', '13:40')
  )
) as regular_id \gset

select is(
  (select count(*)::int from public.bell_period where bell_template_id = :'regular_id'::uuid),
  10,
  'AC: 10 bell_period rows exist for the assembly + 8 teaching + break template'
);
select is(
  (select array_agg(period_no order by segment_ordinal) from public.bell_period
    where bell_template_id = :'regular_id'::uuid and kind = 'TEACHING'),
  array[1,2,3,4,5,6,7,8]::smallint[],
  'AC: the 8 teaching segments are numbered period_no 1 to 8 in order'
);
select is(
  (select count(*)::int from public.bell_period
    where bell_template_id = :'regular_id'::uuid and kind <> 'TEACHING' and period_no is null),
  2,
  'AC: the assembly and break segments carry period_no NULL'
);
select is(
  (select period_no from public.bell_period where bell_template_id = :'regular_id'::uuid and segment_ordinal = 6),
  null::smallint,
  'the break at segment 6 (between period 4 and 5) is not counted as "period 6"'
);
select is(
  (select period_no from public.bell_period where bell_template_id = :'regular_id'::uuid and segment_ordinal = 7),
  5::smallint,
  'the first teaching segment after the break correctly continues at period 5, not 6'
);

-- ── BELL_PERIOD_OVERLAP on save ──────────────────────────────────────────

select throws_ok(
  format(
    $$ select public.create_bell_template(%L, 'MORNING'::public.section_shift, 'OVERLAP', 'Overlap Template', %L::jsonb) $$,
    :'campus_id',
    jsonb_build_array(
      jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
      jsonb_build_object('kind', 'TEACHING', 'start_time', '09:20', 'end_time', '10:10'),
      jsonb_build_object('kind', 'TEACHING', 'start_time', '10:00', 'end_time', '10:40')
    )
  ),
  'BELL_PERIOD_OVERLAP: segments 2 and 3',
  'AC: overlapping segments 2 and 3 are named in the rejection message'
);

-- ── default template per campus+shift ────────────────────────────────────

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'ALT', 'Alt Morning',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:45')
  ),
  true
) as alt_id \gset
select public.set_bell_template_default(:'regular_id'::uuid);
select is(
  (select is_default from public.bell_template where id = :'alt_id'::uuid),
  false,
  'AC: setting a new default unsets the previous one for the same campus+shift'
);
select is(
  (select is_default from public.bell_template where id = :'regular_id'::uuid),
  true,
  'the newly nominated template is now the default'
);
select is(
  (select count(*)::int from public.bell_template where campus_id = :'campus_id'::uuid and shift = 'MORNING' and is_default),
  1,
  'at most one default template exists per campus+shift'
);

-- ── update_bell_period_time ──────────────────────────────────────────────

select segment_ordinal as first_teaching_ordinal, id as first_teaching_id
  from public.bell_period where bell_template_id = :'regular_id'::uuid and segment_ordinal = 2 \gset

select public.update_bell_period_time(:'first_teaching_id'::uuid, '08:03'::time, '08:38'::time);
select is(
  (select start_time::text from public.bell_period where id = :'first_teaching_id'::uuid),
  '08:03:00',
  'AC-adjacent: a segment time can be edited on an unlocked template'
);

select throws_ok(
  format($$ select public.update_bell_period_time(%L, '09:00'::time, '09:10'::time) $$, :'first_teaching_id'),
  'BELL_PERIOD_OVERLAP: segments 2 and 3',
  'editing a segment to overlap a sibling is rejected, naming both segments'
);

-- ── BELL_TEMPLATE_LOCKED ─────────────────────────────────────────────────
-- Nothing in this FR sets is_locked yet (that's the future publish-
-- integration trigger) — simulated directly as ground truth, matching
-- this suite's established "reset role for setup" convention.

reset role;
update public.bell_template set is_locked = true where id = :'regular_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select throws_ok(
  format($$ select public.update_bell_period_time(%L, '08:10'::time, '08:50'::time) $$, :'first_teaching_id'),
  'BELL_TEMPLATE_LOCKED',
  'AC: editing a segment time on a locked template is rejected'
);

reset role;
update public.bell_template set is_locked = false where id = :'regular_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- ── authorization ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format(
    $$ select public.create_bell_template(%L, 'MORNING'::public.section_shift, 'NOPE', 'Nope', %L::jsonb) $$,
    :'campus_id',
    jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'))
  ),
  'FORBIDDEN',
  'AC: a subject teacher cannot create a bell template'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select throws_ok(
  format(
    $$ select public.create_bell_template(%L, 'MORNING'::public.section_shift, 'NOPE', 'Nope', %L::jsonb) $$,
    gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'))
  ),
  'CAMPUS_NOT_FOUND',
  'an unknown/foreign campus id is rejected'
);

select throws_ok(
  $$ select public.create_bell_template(
       (select id from public.campus limit 1), 'MORNING'::public.section_shift, 'EMPTY', 'Empty', '[]'::jsonb
     ) $$,
  'BELL_TEMPLATE_EMPTY',
  'a template with zero segments is rejected'
);

-- ── duplicate code ────────────────────────────────────────────────────────

select throws_ok(
  format(
    $$ select public.create_bell_template(%L, 'MORNING'::public.section_shift, 'REGULAR', 'Duplicate Code', %L::jsonb) $$,
    :'campus_id',
    jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '14:00', 'end_time', '14:40'))
  ),
  'BELL_TEMPLATE_CODE_DUPLICATE',
  'a duplicate code for the same campus+shift is rejected'
);

-- ── RLS: cross-campus and cross-tenant isolation ────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus2_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.bell_template where id = :'regular_id'::uuid),
  0,
  'a staff member scoped to a different campus cannot see this campus''s bell template'
);
select is(
  (select count(*)::int from public.bell_period where bell_template_id = :'regular_id'::uuid),
  0,
  'the same staff member cannot see this campus''s bell periods either'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'), 'sub', gen_random_uuid())::text,
  true
);
select is(
  (select count(*)::int from public.bell_template where id = :'regular_id'::uuid),
  0,
  'a different tenant entirely cannot see this bell template'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.bell_template where campus_id = :'campus_id'::uuid),
  2,
  'the owner (whole-tenant scope) sees both successfully-created templates for this campus'
);

select * from finish();
rollback;
