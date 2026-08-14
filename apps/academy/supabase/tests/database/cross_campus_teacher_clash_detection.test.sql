-- pgTAP tests for 20260801020000_cross_campus_teacher_clash_detection.sql.
--
-- The defect: 20260731770000_security_definer_campus_scope_audit.sql made
-- resolve_bell_template_for_weekday() return NULL for a campus outside the
-- caller's campus_ids claim. public.v_slot_clock_time INNER joins
-- bell_period on that resolution, so a competing slot at another campus
-- dropped out of the view — and upsert_timetable_slot()'s TEACHER_CLASH
-- check (FR-F05), which queries that view tenant-wide by staff_id on
-- purpose, stopped seeing it. A Principal scoped to campus A could
-- double-book a teacher already teaching at campus B, with no exception.
-- create_substitution()'s SUBSTITUTE_CLASH (FR-D13) had it identically.
--
-- This file proves all three halves with ONE Principal scoped to campus A
-- only:
--   * the clash IS raised — the safety control fires again;
--   * the message it raises names nothing about campus B (asserted by
--     exact equality, so no other field can hide in it), while an
--     in-scope clash still names the section and its clock range;
--   * that same Principal still cannot read campus B through any of the
--     public surfaces, and cannot reach the internal unscoped ones at all.
begin;
select plan(16);

select public.provision_tenant('test-xcampus-clash-co', 'Cross Campus Clash Co', 'owner@xcampusclash.test');
select id as tenant_id from public.tenant where slug = 'test-xcampus-clash-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@xcampusclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Clash Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@xcampusclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Clash Principal');

-- The teacher both campuses want at 08:30 on Monday.
select gen_random_uuid() as shared_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'shared_uid', 'shared@xcampusclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'shared_uid', :'tenant_id', 'subject_teacher', 'Shared Teacher');

select gen_random_uuid() as absent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'absent_uid', 'absent@xcampusclash.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'absent_uid', :'tenant_id', 'subject_teacher', 'Absent Teacher');

-- Runs the statement as the CURRENT role and hands back its error message
-- verbatim (null when it did not raise), so a test can assert on what the
-- message does NOT contain, not merely that something was thrown.
create or replace function pg_temp.error_message(p_sql text)
returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end;
$$;

-- Same superuser bracketing every other suite uses for campus: no INSERT
-- policy exists for `authenticated` on it.
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_uid')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
-- Distinctive names, so "the message does not mention campus B" can be
-- asserted against a token that could not appear by accident.
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Alpha', 40) as section_alpha \gset
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Bravo', 40) as section_bravo \gset
select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Zulu', 40) as section_zulu \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.upsert_class_subject(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 6::smallint);
select public.upsert_class_subject(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 6::smallint);
select public.create_staff_teachable_subject(:'shared_uid'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'absent_uid'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

-- Monday period 1 is 08:00-08:40 at campus A and 08:20-09:00 at campus B:
-- overlapping, but not identical, so "resolved the other campus's own bell
-- template" and "reused this campus's" cannot be confused.
select public.create_bell_template(
  :'campus_a_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'North Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40')),
  true
) as template_a_id \gset
select public.create_bell_template(
  :'campus_b_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'South Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:20', 'end_time', '09:00')),
  true
) as template_b_id \gset

select public.create_timetable_version(:'campus_a_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'North Draft') as version_a_id \gset
select public.create_timetable_version(:'campus_b_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'South Draft') as version_b_id \gset

-- The competing booking, made by the one actor who can see both campuses.
select public.upsert_timetable_slot(:'version_b_id'::uuid, :'section_zulu'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'shared_uid'::uuid) as slot_zulu \gset
-- A campus A period for the substitution arm to try to cover.
select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_bravo'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'absent_uid'::uuid) as slot_bravo \gset

-- ── The Principal, scoped to campus A ONLY ─────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'principal_uid')::text,
  true
);

select throws_ok(
  format($$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 1::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
         :'version_a_id', :'section_alpha', :'physics_id', :'shared_uid'),
  '23514',
  null,
  'FR-F05 holds again: a Principal scoped to campus A cannot double-book a teacher who is already teaching at campus B'
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'version_a_id'::uuid and section_id = :'section_alpha'::uuid),
  0,
  'and the rejected write left no slot behind'
);

-- ── What that refusal is allowed to say ────────────────────────────────
-- Exact equality, not a pattern: it proves the message carries the campus
-- B section name, class, subject, room, campus code and competing clock
-- range NOWHERE, rather than merely proving the few tokens checked below
-- are absent.

select is(
  pg_temp.error_message(format(
    $$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 1::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
    :'version_a_id', :'section_alpha', :'physics_id', :'shared_uid')),
  'TEACHER_CLASH: this teacher is already booked at another campus in an overlapping period',
  'the out-of-scope refusal says a clash happened and nothing else'
);
select doesnt_match(
  pg_temp.error_message(format(
    $$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 1::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
    :'version_a_id', :'section_alpha', :'physics_id', :'shared_uid')),
  'Zulu',
  'it does not name campus B''s section'
);
select doesnt_match(
  pg_temp.error_message(format(
    $$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 1::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
    :'version_a_id', :'section_alpha', :'physics_id', :'shared_uid')),
  'SOUTH|South',
  'nor campus B itself'
);
select doesnt_match(
  pg_temp.error_message(format(
    $$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 1::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
    :'version_a_id', :'section_alpha', :'physics_id', :'shared_uid')),
  '08:20|09:00',
  'nor the clock range of the period she is actually teaching'
);

-- An IN-scope clash is unchanged: the caller can already read that
-- section, so withholding it would only make the refusal harder to fix.
select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_alpha'::uuid, 2::smallint, 1::smallint, :'physics_id'::uuid, :'shared_uid'::uuid) as slot_alpha_tue \gset
select is(
  pg_temp.error_message(format(
    $$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 2::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
    :'version_a_id', :'section_bravo', :'physics_id', :'shared_uid')),
  'TEACHER_CLASH: section Alpha at 08:00-08:40',
  'a same-campus clash still names the section and its clock range'
);

-- ── FR-D13's SUBSTITUTE_CLASH, the same invariant, the same defect ─────

select throws_ok(
  format($$ select public.create_substitution(%L::uuid, %L::date, %L::uuid, 'other'::public.substitution_reason) $$,
         :'slot_bravo', '2026-08-03', :'shared_uid'),
  '23514',
  'SUBSTITUTE_CLASH',
  'a substitute already teaching at campus B in that period is refused too'
);

-- ── The audit's guard still holds for this same Principal ──────────────

select is(
  (select public.resolve_bell_template_for_weekday(:'campus_b_id'::uuid, 'MORNING'::public.section_shift, 1::smallint)),
  null,
  'the campus guard is untouched: campus B still resolves to NULL through the public resolver'
);
select is(
  (select public.resolve_bell_template_for_weekday(:'campus_a_id'::uuid, 'MORNING'::public.section_shift, 1::smallint)),
  :'template_a_id'::uuid,
  'while her own campus A resolves normally'
);
select is(
  (select count(*)::int from public.v_slot_clock_time where slot_id = :'slot_zulu'::uuid),
  0,
  'and campus B''s slot is still invisible to her through public.v_slot_clock_time'
);
select is(
  (select count(*)::int from public.timetable_slot where id = :'slot_zulu'::uuid),
  0,
  'and through the base table, which is what makes that view''s emptiness real rather than cosmetic'
);

-- ── The escape hatches are not general-purpose bypasses ────────────────
-- `authenticated` holds USAGE on schema app (foundation.sql), so the
-- revoked EXECUTE/SELECT is the only thing standing between a caller and
-- the unguarded objects — assert both directly rather than trusting the
-- grants.

select throws_ok(
  format($$ select app.resolve_bell_template_for_weekday_unscoped(%L::uuid, 'MORNING'::public.section_shift, 1::smallint) $$, :'campus_b_id'),
  '42501',
  null,
  'authenticated cannot call the unscoped weekday resolver directly'
);
select throws_ok(
  format($$ select count(*) from app.v_slot_clock_time_unscoped where slot_id = %L::uuid $$, :'slot_zulu'),
  '42501',
  null,
  'nor read the unscoped clock-time view'
);

-- ── An Owner sees what an Owner always saw ─────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_uid')::text,
  true
);
select is(
  pg_temp.error_message(format(
    $$ select public.upsert_timetable_slot(%L::uuid, %L::uuid, 1::smallint, 1::smallint, %L::uuid, %L::uuid) $$,
    :'version_a_id', :'section_alpha', :'physics_id', :'shared_uid')),
  'TEACHER_CLASH: section Zulu at 08:20-09:00',
  'an Owner, who may read both campuses, still gets the fully detailed message'
);
select is(
  (select count(*)::int from public.v_slot_clock_time where slot_id = :'slot_zulu'::uuid),
  1,
  'and campus B''s slot is visible to the Owner through the public view, as it always was'
);

select * from finish();
rollback;
