-- pgTAP tests for FR-F12 (per-teacher timetable view).
begin;
select plan(12);

select public.provision_tenant('test-teachertt-co', 'Teacher TT Co', 'owner@teachertt.test');
select id as tenant_id from public.tenant where slug = 'test-teachertt-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@teachertt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as ayesha_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ayesha_user_id', 'ayesha@teachertt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ayesha_user_id', :'tenant_id', 'subject_teacher', 'Ms Ayesha');

select gen_random_uuid() as other_teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'other_teacher_user_id', 'other@teachertt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'other_teacher_user_id', :'tenant_id', 'subject_teacher', 'Mr Other');

select gen_random_uuid() as absent_teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'absent_teacher_user_id', 'absent@teachertt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'absent_teacher_user_id', :'tenant_id', 'subject_teacher', 'Mr Absent');

select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal@teachertt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id', 'principal', 'The Principal');

select gen_random_uuid() as hr_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'hr_user_id', 'hr@teachertt.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'hr_user_id', :'tenant_id', 'hr_manager', 'The HR Manager');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_user_id')::text,
  true
);

-- A second campus, so Ms Ayesha's own cross-campus AC is genuine — its
-- own bell template's period 1 runs at a DIFFERENT clock time than
-- campus A's, proving the resolution is truly per-campus. No INSERT
-- policy exists for `authenticated` on campus (only provision_tenant's
-- own SECURITY DEFINER path writes it), so this direct insert needs the
-- same reset-role bracketing as every other superuser-only write this
-- suite performs after its first role switch.
reset role;
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_user_id')::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a_id \gset
select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset

select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
-- Matches exactly what gets scheduled below (section A: weekday_a +
-- weekday_sub = 2; section B: weekday_b = 1) so publish_timetable()'s own
-- quota gate (FR-F09) never blocks this FR's own, unrelated test.
select public.upsert_class_subject(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 2::smallint);
select public.upsert_class_subject(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 1::smallint);

select public.create_staff_teachable_subject(:'ayesha_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);
select public.create_staff_teachable_subject(:'absent_teacher_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

select public.create_bell_template(
  :'campus_a_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'North Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40')),
  true
) as template_a_id \gset
select public.create_bell_template(
  :'campus_b_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'South Regular',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:40')),
  true
) as template_b_id \gset

-- AC (Ramadan): a second template for campus A, active only across one
-- specific date, with period 1 shortened.
select public.create_bell_template(
  :'campus_a_id'::uuid, 'MORNING'::public.section_shift, 'RAMADAN', 'North Ramadan',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '07:30', 'end_time', '08:00')),
  false
) as ramadan_template_a_id \gset

select public.create_timetable_version(:'campus_a_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'North Draft') as version_a_id \gset
select public.create_timetable_version(:'campus_b_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'South Draft') as version_b_id \gset

-- A fixed reference date (never "today") whose own weekday drives every
-- slot below, so the function's date_trunc('week', ...) resolution is
-- exercised against a real, self-consistent calendar week rather than a
-- guessed weekday number.
select extract(dow from date '2026-08-03')::smallint as weekday_a \gset
select (date '2026-08-03' + 1) as ref_date_b \gset
select extract(dow from :'ref_date_b'::date)::smallint as weekday_b \gset
select (date '2026-08-03' + 2) as ref_date_sub \gset
select extract(dow from :'ref_date_sub'::date)::smallint as weekday_sub \gset

-- Ms Ayesha: period 1 at campus A (her own weekday_a), and period 1 at
-- campus B on a different weekday the same week — the actual cross-
-- campus AC.
select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_a_id'::uuid, :'weekday_a'::smallint, 1::smallint, :'physics_id'::uuid, :'ayesha_user_id'::uuid) as slot_a_id \gset
select public.upsert_timetable_slot(:'version_b_id'::uuid, :'section_b_id'::uuid, :'weekday_b'::smallint, 1::smallint, :'physics_id'::uuid, :'ayesha_user_id'::uuid) as slot_b_id \gset

-- Mr Absent's own period, which Ms Ayesha substitutes for this week.
select public.upsert_timetable_slot(:'version_a_id'::uuid, :'section_a_id'::uuid, :'weekday_sub'::smallint, 1::smallint, :'physics_id'::uuid, :'absent_teacher_user_id'::uuid) as slot_sub_id \gset

select public.publish_timetable(:'version_a_id'::uuid, '2026-01-01'::date) as published_a_id \gset
select public.publish_timetable(:'version_b_id'::uuid, '2026-01-01'::date) as published_b_id \gset

select public.create_substitution(:'slot_sub_id'::uuid, :'ref_date_sub'::date, :'ayesha_user_id'::uuid, 'other') as substitution_id \gset

-- ── AC1/AC (cross-campus): campus A and campus B resolve their own real times ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'ayesha_user_id')::text,
  true
);

select is(
  (select campus_code from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_a_id' and not is_substitution),
  (select code from public.campus where id = :'campus_a_id'),
  'AC: campus A''s own period is labelled with campus A''s code'
);
select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_a_id' and not is_substitution),
  '08:00:00',
  'AC: campus A''s period resolves campus A''s own bell time'
);
select is(
  (select campus_code from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_b_id'),
  (select code from public.campus where id = :'campus_b_id'),
  'AC (cross-campus): campus B''s own period is labelled with campus B''s code, in the SAME weekly view'
);
select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_b_id'),
  '09:00:00',
  'AC (cross-campus): campus B''s period resolves campus B''s own, DIFFERENT bell time'
);
select is(
  (select bool_and(not is_substitution) from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where weekday in (:'weekday_a', :'weekday_b')),
  true,
  'her own regular periods are never flagged as substitutions'
);

-- ── AC3: this week's substitution coverage overlays the regular grid ────

select is(
  (select is_substitution from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where occurs_on = :'ref_date_sub'::date and section_id = :'section_a_id' and absent_teacher_name is not null),
  true,
  'AC3: the period she is covering this week is flagged as a substitution'
);
select is(
  (select absent_teacher_name from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where occurs_on = :'ref_date_sub'::date and is_substitution),
  'Mr Absent',
  'AC3: it names the teacher she is covering for'
);

-- ── AC5: a Ramadan-range date resolves the Ramadan template''s own times ──
-- Same weekday, 4 weeks later (a genuinely different calendar week), with
-- the Ramadan calendar rule active only on that one exact date.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_user_id')::text,
  true
);
select public.create_bell_calendar_rule(:'campus_a_id'::uuid, 'MORNING'::public.section_shift, :'ramadan_template_a_id'::uuid, null::smallint, (date '2026-08-03' + 28)::date, (date '2026-08-03' + 28)::date, 100::smallint);
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'ayesha_user_id')::text,
  true
);

select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, (date '2026-08-03' + 28)::date) where section_id = :'section_a_id'),
  '07:30:00',
  'AC5: a date inside the Ramadan range resolves the Ramadan template''s own (shortened) period 1'
);
select is(
  (select start_time::text from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_a_id' and not is_substitution),
  '08:00:00',
  'the ordinary week (outside the Ramadan range) is completely unaffected by that rule'
);

-- ── AC4: RLS-equivalent access control ──────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'other_teacher_user_id')::text,
  true
);
select throws_ok(
  format($$ select * from public.teacher_timetable(%L, '2026-08-03'::date) $$, :'ayesha_user_id'),
  'FORBIDDEN',
  'AC4: another Teacher requesting Ms Ayesha''s own timetable is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'principal_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_a_id' and not is_substitution),
  1,
  'AC4: a Principal CAN view another teacher''s timetable'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id'), 'sub', :'hr_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.teacher_timetable(:'ayesha_user_id'::uuid, '2026-08-03'::date) where section_id = :'section_a_id' and not is_substitution),
  1,
  'AC4: an HR Manager CAN view another teacher''s timetable too'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'owner_user_id')::text,
  true
);

select * from finish();
rollback;
