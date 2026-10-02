-- pgTAP tests for FR-H03 (daily homework load cap per section).
begin;
select plan(13);

select public.provision_tenant('test-hw-load-co', 'HW Load Co', 'owner@hwloadco.test');
select id as tenant_id from public.tenant where slug = 'test-hw-load-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@hwloadco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Load Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset
select public.create_subject('MATH', 'Maths', 'ریاضی') as maths_id \gset
select public.create_subject('URD', 'Urdu', 'اردو') as urdu_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'maths_id'::uuid, 5::smallint);
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'urdu_id'::uuid, 5::smallint);
select public.assign_subject_teacher(:'section_id'::uuid, :'maths_id'::uuid, :'teacher_user_id'::uuid, '2026-08-01'::date);
select public.assign_subject_teacher(:'section_b_id'::uuid, :'maths_id'::uuid, :'teacher_user_id'::uuid, '2026-08-01'::date);

-- A subject teacher (not principal-tier) cannot set the campus policy.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.set_homework_load_policy(%L, %L, 3::int, 90::int) $$, :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a subject teacher cannot set the homework load policy'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.set_homework_load_policy(:'campus_id'::uuid, :'session_id'::uuid, 3::int, 90::int);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);

-- ── AC3: a draft never counts toward the load — only what's published ──

select public.create_homework(:'section_id'::uuid, :'maths_id'::uuid, 'Unpublished draft', '2026-08-20'::date, '2026-08-13'::date, null::text, 20::int, 'draft'::public.homework_status) as draft_id \gset
select is(
  (select count(*)::int from public.v_section_homework_load where section_id = :'section_id'::uuid and due_date = '2026-08-20'::date),
  0,
  'AC: an unpublished draft never appears in the section load view'
);

-- ── AC1: the first 3 (at the cap) publish clean, no warning ─────────────

select public.create_homework(:'section_id'::uuid, :'maths_id'::uuid, 'Assignment 1', '2026-08-20'::date, '2026-08-13'::date, null::text, 20::int) as hw1_id \gset
select public.publish_homework(:'hw1_id'::uuid) as pub1 \gset
select ok((:'pub1'::jsonb ->> 'warning') is null, 'the 1st assignment for that section+date publishes with no warning');

select public.create_homework(:'section_id'::uuid, :'maths_id'::uuid, 'Assignment 2', '2026-08-20'::date, '2026-08-13'::date, null::text, 25::int) as hw2_id \gset
select public.publish_homework(:'hw2_id'::uuid) as pub2 \gset
select ok((:'pub2'::jsonb ->> 'warning') is null, 'the 2nd assignment publishes with no warning');

select public.create_homework(:'section_id'::uuid, :'maths_id'::uuid, 'Assignment 3', '2026-08-20'::date, '2026-08-13'::date, null::text, 30::int) as hw3_id \gset
select public.publish_homework(:'hw3_id'::uuid) as pub3 \gset
select ok((:'pub3'::jsonb ->> 'warning') is null, 'the 3rd assignment (right at the cap) still publishes with no warning');

-- ── AC1: the 4th assignment for the same section+date carries the
--    non-blocking warning, and still saves as published ──────────────

select public.create_homework(:'section_id'::uuid, :'maths_id'::uuid, 'Assignment 4', '2026-08-20'::date, '2026-08-13'::date, null::text, 20::int) as hw4_id \gset
select public.publish_homework(:'hw4_id'::uuid) as pub4 \gset
select is(
  (:'pub4'::jsonb ->> 'warning'),
  'SECTION_HOMEWORK_LOAD_CAP',
  'AC1: the 4th assignment for the same section+date carries the load-cap warning'
);
select ok(
  (:'pub4'::jsonb ->> 'message') like '%already has 3 assignment(s) due%(est. 75 min)%',
  'AC1: the warning message states the prior count and prior total minutes'
);
select is(
  (select status from public.homework where id = :'hw4_id'::uuid)::text,
  'published',
  'AC1: the warning never blocked the publish — it saved regardless'
);
select ok(
  (select load_warning_overridden from public.homework where id = :'hw4_id'::uuid),
  'the override is recorded on the row'
);
select is(
  (select overridden_by from public.homework where id = :'hw4_id'::uuid),
  :'teacher_user_id'::uuid,
  'the override records the actual publishing teacher''s id'
);

-- ── AC2: the section load view sums count and minutes correctly ────────

select is(
  (select assignment_count from public.v_section_homework_load where section_id = :'section_id'::uuid and due_date = '2026-08-20'::date),
  4,
  'AC2: the load view counts all 4 published assignments for that section+date'
);
select is(
  (select total_minutes from public.v_section_homework_load where section_id = :'section_id'::uuid and due_date = '2026-08-20'::date),
  95,
  'AC2: the load view sums estimated minutes across all 4 (20+25+30+20)'
);

-- ── AC3: a section with no policy at all (different campus/session
--    scope was never configured) publishes with no warning regardless
--    of how many are already due — section B here shares the SAME
--    campus/session as A but the cap is per (campus,session), so this
--    just proves the check is scoped correctly and doesn''t leak across
--    a different section under the same, already-armed policy. ──────
select public.create_homework(:'section_b_id'::uuid, :'maths_id'::uuid, 'B Assignment 1', '2026-08-20'::date, '2026-08-13'::date, null::text, 20::int) as hwb1_id \gset
select public.publish_homework(:'hwb1_id'::uuid) as pubb1 \gset
select ok(
  (:'pubb1'::jsonb ->> 'warning') is null,
  'AC: the load check is scoped per section — section B''s own first assignment carries no warning even though the campus policy is armed'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select * from finish();
rollback;
