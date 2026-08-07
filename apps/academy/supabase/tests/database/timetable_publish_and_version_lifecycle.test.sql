-- pgTAP tests for FR-F10 (timetable version lifecycle) and FR-F09
-- (timetable publish validation gate), built together — see the
-- migration's own header for why F10 alone has no reachable ACs.
begin;
select plan(23);

select public.provision_tenant('test-publish-co', 'Publish Co', 'owner@publishco.test');
select id as tenant_id from public.tenant where slug = 'test-publish-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@publishco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as exam_controller_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'exam_controller_user_id', 'ec@publishco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'exam_controller_user_id', :'tenant_id', 'exam_controller', 'Exam Controller');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@publishco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Mr Ali');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.create_subject('CHM', 'Chemistry', 'کیمسٹری') as chem_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 2::smallint);
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'chem_id'::uuid, 1::smallint);

select public.create_staff_teachable_subject(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'teacher_user_id'::uuid, :'chem_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:00', 'end_time', '10:40')
  ),
  true
);

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Term 1') as v1_id \gset

-- Physics fully scheduled (2/2, one of the two periods left unstaffed —
-- AC2's own "warning", never blocking); Chemistry not scheduled at all
-- (0/1 — a genuine AC1/AC3 shortfall).
select public.upsert_timetable_slot(:'v1_id'::uuid, :'section_a_id'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid);
select public.upsert_timetable_slot(:'v1_id'::uuid, :'section_a_id'::uuid, 1::smallint, 2::smallint, :'physics_id'::uuid);

-- ── v_scheduled_vs_required_periods ─────────────────────────────────────

select is(
  (select scheduled_periods from public.v_scheduled_vs_required_periods where timetable_version_id = :'v1_id' and subject_code = 'PHY'),
  2::bigint,
  'Physics shows 2 scheduled periods against its own requirement'
);
select is(
  (select scheduled_periods from public.v_scheduled_vs_required_periods where timetable_version_id = :'v1_id' and subject_code = 'CHM'),
  0::bigint,
  'Chemistry, never scheduled at all, still appears with 0 scheduled periods (never silently absent from the view)'
);

-- ── AC (F09): publish blocked by a genuine shortfall, named in the error ──

select throws_ok(
  format($$ select public.publish_timetable(%L, '2026-01-01'::date) $$, :'v1_id'),
  'QUOTA_SHORTFALL: A CHM 0/1',
  'AC: publish with no override reason is blocked, naming the exact section/subject/scheduled/required shortfall'
);
select throws_ok(
  format($$ select public.publish_timetable(%L, '2026-01-01'::date, 'too short') $$, :'v1_id'),
  'QUOTA_SHORTFALL: A CHM 0/1',
  'AC: an override reason under 10 characters is treated the same as no reason at all'
);

-- ── AC (F09): publish succeeds with a real override reason ──────────────

select public.publish_timetable(:'v1_id'::uuid, '2026-01-01'::date, 'temporary vacancy, Chemistry teacher joins next week') as published_id \gset
select is(
  (select status::text from public.timetable_version where id = :'v1_id'),
  'PUBLISHED',
  'AC: the override path actually publishes the version'
);
select is(
  (select effective_from::text from public.timetable_version where id = :'v1_id'),
  '2026-01-01',
  'effective_from is stamped as given'
);
select ok(
  (select effective_to is null from public.timetable_version where id = :'v1_id'),
  'a freshly published version is open-ended — no effective_to yet'
);
select is(
  (select warning_count from public.timetable_version where id = :'v1_id'),
  1,
  'AC2: warning_count stores the 1 unstaffed Physics period, distinct from (and not blocked by) the Chemistry shortfall'
);
select is(
  (select count(*)::int from public.timetable_publish_exception where timetable_version_id = :'v1_id'),
  1,
  'AC: exactly one exception row is written, for Chemistry'
);
select is(
  (select scheduled_periods from public.timetable_publish_exception where timetable_version_id = :'v1_id'),
  0::smallint,
  'the exception row records the actual scheduled count at publish time'
);

-- ── AC1: a published version''s slots are immutable ─────────────────────

select throws_ok(
  format(
    $$ select public.upsert_timetable_slot(%L, %L, 2::smallint, 1::smallint, %L, %L) $$,
    :'v1_id', :'section_a_id', :'physics_id', :'teacher_user_id'
  ),
  'VERSION_IMMUTABLE',
  'AC1: writing to a slot on a genuinely Published version (reached via the real publish path) is rejected'
);

-- ── AC3: resolve_timetable_version ───────────────────────────────────────

select is(
  public.resolve_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, '2026-03-15'::date),
  :'v1_id'::uuid,
  'AC3: a date inside v1''s open range resolves to v1'
);
select ok(
  public.resolve_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, '2025-12-31'::date) is null,
  'a date before any version was ever published resolves to nothing'
);

-- ── AC2: clone + republish supersedes the prior version ──────────────────

select public.clone_timetable_version(:'v1_id'::uuid) as v2_id \gset
select is(
  (select version_no from public.timetable_version where id = :'v2_id'),
  2::smallint,
  'the clone gets the next version_no for this campus/session'
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'v2_id'),
  2,
  'the clone copies both of v1''s slots (Chemistry was never scheduled, so there was nothing to copy for it)'
);

-- Fill in the missing Chemistry period on the clone — now 0 shortfalls,
-- Physics'' period 2 stays unstaffed so v2''s own publish exercises
-- warning_count independently too.
select public.upsert_timetable_slot(:'v2_id'::uuid, :'section_a_id'::uuid, 1::smallint, 3::smallint, :'chem_id'::uuid, :'teacher_user_id'::uuid);

select public.publish_timetable(:'v2_id'::uuid, '2026-06-01'::date) as published2_id \gset
select is(
  (select status::text from public.timetable_version where id = :'v1_id'),
  'SUPERSEDED',
  'AC2: publishing v2 (a genuinely later effective_from) moves v1 to Superseded'
);
select is(
  (select effective_to::text from public.timetable_version where id = :'v1_id'),
  '2026-05-31',
  'AC2: v1''s effective_to is the day before v2''s effective_from, exactly as the AC states it'
);
select is(
  (select status::text from public.timetable_version where id = :'v2_id'),
  'PUBLISHED',
  'v2 is now the open, currently-in-force version'
);

-- ── AC3 again: the date resolver now splits between the two ranges ──────

select is(
  public.resolve_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, '2026-03-01'::date),
  :'v1_id'::uuid,
  'AC3: a date inside v1''s now-closed range still resolves to v1 — attendance from that term still points at the timetable that was actually in force'
);
select is(
  public.resolve_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, '2026-07-01'::date),
  :'v2_id'::uuid,
  'AC3: a date in v2''s range resolves to v2'
);

-- ── AC4: backdating a publish into an already-open range is rejected ────

-- v3 is a full clone of v2 (already 0 shortfalls) — nothing more to add.
select public.clone_timetable_version(:'v2_id'::uuid) as v3_id \gset
select throws_ok(
  format($$ select public.publish_timetable(%L, '2026-02-01'::date) $$, :'v3_id'),
  'VERSION_RANGE_OVERLAP',
  'AC4: publishing with an effective_from that falls before the currently-open version''s own start is rejected, not silently treated as a supersession'
);

-- ── authorization ─────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'exam_controller_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.publish_timetable(%L, '2026-02-01'::date) $$, :'v3_id'),
  'FORBIDDEN',
  'an Exam Controller cannot publish — only Principal/Owner/Super Admin, per this FR''s own RLS spec'
);
select ok(
  public.clone_timetable_version(:'v2_id'::uuid) is not null,
  'an Exam Controller CAN clone a version — cloning is a drafting action, not the publish gate'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select * from finish();
rollback;
