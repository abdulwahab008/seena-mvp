-- pgTAP tests for 20260801070000_substitute_suggestion_campus_guard.sql.
--
-- The defect: suggest_substitutes() (FR-D13) checks the caller's ROLE
-- but never checked the slot's CAMPUS, unlike its sibling
-- create_substitution(), which has refused an out-of-scope slot with
-- FORBIDDEN since it shipped. The slot's own clock range is resolved
-- through resolve_bell_template_for_weekday(), which
-- 20260731770000_security_definer_campus_scope_audit.sql taught to
-- return NULL for a campus outside the caller's campus_ids claim, so
-- v_self_start came back NULL and is_free's first branch —
-- `v_self_start is null or ...` — reported EVERY teacher in the tenant
-- as free, with no error, ranked free-first.
--
-- This is a new refusal path, so the file proves both halves: the
-- out-of-scope call now refuses loudly with the same code and message
-- the write already used, and the legitimate same-campus call is
-- untouched and still distinguishes a busy candidate from a free one.
begin;
select plan(13);

select public.provision_tenant('test-sub-suggest-scope-co', 'Sub Suggest Scope Co', 'owner@subsuggestscope.test');
select id as tenant_id from public.tenant where slug = 'test-sub-suggest-scope-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@subsuggestscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Suggest Owner');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@subsuggestscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'North Principal');

-- absent_a teaches the campus A period being covered, absent_b the
-- campus B one; busy is already teaching at campus A in that same
-- period; free is teaching nothing at all.
select gen_random_uuid() as absent_a_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'absent_a_uid', 'absent-a@subsuggestscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'absent_a_uid', :'tenant_id', 'subject_teacher', 'Absent North');

select gen_random_uuid() as absent_b_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'absent_b_uid', 'absent-b@subsuggestscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'absent_b_uid', :'tenant_id', 'subject_teacher', 'Absent South');

select gen_random_uuid() as busy_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'busy_uid', 'busy@subsuggestscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'busy_uid', :'tenant_id', 'subject_teacher', 'Busy Teacher');

select gen_random_uuid() as free_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'free_uid', 'free@subsuggestscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'free_uid', :'tenant_id', 'subject_teacher', 'Free Teacher');

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'owner_uid')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Alpha', 40) as section_alpha \gset
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Bravo', 40) as section_bravo \gset
select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Zulu', 40) as section_zulu \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.upsert_class_subject(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 6::smallint);
select public.upsert_class_subject(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 6::smallint);
select public.create_staff_teachable_subject(:'absent_a_uid'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'absent_b_uid'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'busy_uid'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

-- Monday period 1 is 08:00-08:40 at campus A and 08:20-09:00 at campus B.
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

select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_alpha'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'absent_a_uid'::uuid) as slot_alpha \gset
select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_bravo'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'busy_uid'::uuid) as slot_bravo \gset
select public.upsert_timetable_slot(:'version_b_id'::uuid, :'section_zulu'::uuid, 1::smallint, 1::smallint, :'physics_id'::uuid, :'absent_b_uid'::uuid) as slot_zulu \gset

-- ── The Principal, scoped to campus A ONLY ─────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'principal_uid')::text,
  true
);

select throws_ok(
  format($$ select * from public.suggest_substitutes(%L::uuid, '2026-08-03'::date) $$, :'slot_zulu'),
  '42501',
  'FORBIDDEN',
  'a Principal scoped to campus A is refused outright for a campus B slot — she used to get a full candidate list with everyone reported free'
);
select throws_ok(
  format($$ select public.create_substitution(%L::uuid, '2026-08-03'::date, %L::uuid, 'other'::public.substitution_reason) $$,
         :'slot_zulu', :'free_uid'),
  '42501',
  'FORBIDDEN',
  'and the write it feeds refuses that same slot with the same code and message — read and write now agree'
);

-- ── The same refusal for the empty claim ───────────────────────────────
-- '{}' contains no campus, so `not (campus = any('{}'))` is true
-- everywhere. create_substitution() already refused such a caller, so
-- matching it is what keeps the screen from offering a candidate the
-- write then rejects.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$ select * from public.suggest_substitutes(%L::uuid, '2026-08-03'::date) $$, :'slot_alpha'),
  '42501',
  'FORBIDDEN',
  'a Principal with an empty campus_ids claim is refused by the suggestion list'
);
select throws_ok(
  format($$ select public.create_substitution(%L::uuid, '2026-08-03'::date, %L::uuid, 'other'::public.substitution_reason) $$,
         :'slot_alpha', :'free_uid'),
  '42501',
  'FORBIDDEN',
  'exactly as create_substitution() already refused her for the identical slot — one rule, not two'
);

-- ── The legitimate same-campus case is untouched ───────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'principal_uid')::text,
  true
);
select is(
  (select count(*)::int from public.suggest_substitutes(:'slot_alpha'::uuid, '2026-08-03'::date)),
  3,
  'her own campus A slot still returns every candidate except the absent teacher'
);
select is(
  (select is_free from public.suggest_substitutes(:'slot_alpha'::uuid, '2026-08-03'::date) where staff_id = :'busy_uid'::uuid),
  false,
  'and a teacher already booked in that period is still correctly reported busy'
);
select is(
  (select is_free from public.suggest_substitutes(:'slot_alpha'::uuid, '2026-08-03'::date) where staff_id = :'free_uid'::uuid),
  true,
  'while a teacher with nothing booked is still reported free'
);
select is(
  (select is_free from public.suggest_substitutes(:'slot_alpha'::uuid, '2026-08-03'::date) where staff_id = :'absent_b_uid'::uuid),
  false,
  'and 20260801020000 still holds: a candidate busy at the OTHER campus in that period is not reported free'
);
select lives_ok(
  format($$ select public.create_substitution(%L::uuid, '2026-08-03'::date, %L::uuid, 'other'::public.substitution_reason) $$,
         :'slot_alpha', :'free_uid'),
  'and she can still actually assign the free candidate the list offered her'
);

-- ── An Owner is exempt, exactly as create_substitution() exempts one ────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select count(*)::int from public.suggest_substitutes(:'slot_zulu'::uuid, '2026-08-03'::date)),
  3,
  'an Owner whose claim covers campus A only still gets campus B''s candidate list, as she always did'
);
select is(
  (select is_free from public.suggest_substitutes(:'slot_zulu'::uuid, '2026-08-03'::date) where staff_id = :'busy_uid'::uuid),
  false,
  'and it is a real answer: the campus A teacher whose 08:00-08:40 period overlaps campus B''s 08:20-09:00 is reported busy'
);

-- ── The audit's guard still holds for the refused Principal ────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'principal_uid')::text,
  true
);
select is(
  (select public.resolve_bell_template_for_weekday(:'campus_b_id'::uuid, 'MORNING'::public.section_shift, 1::smallint)),
  null,
  'the campus guard is untouched: campus B still resolves to NULL through the public resolver'
);
select is(
  (select count(*)::int from public.timetable_slot where id = :'slot_zulu'::uuid),
  0,
  'and campus B''s slot is still unreadable to her through the base table'
);

select * from finish();
rollback;
