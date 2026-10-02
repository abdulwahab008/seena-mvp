-- pgTAP tests for FR-F03 (Ramadan schedule override).
begin;
select plan(28);

select public.provision_tenant('test-ramadan-co', 'Ramadan Co', 'owner@ramadanco.test');
select id as tenant_id from public.tenant where slug = 'test-ramadan-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@ramadanco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal@ramadanco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id', 'principal', 'The Principal');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'imran@ramadanco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'Mr Imran');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- A second campus, for the campus-scoping assertions at the end.
reset role;
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Girls Campus', 'GIRLS') returning id as girls_campus_id \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'girls_campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- The regular day: 8 teaching periods.
select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular Day',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:40', 'end_time', '09:20'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:20', 'end_time', '10:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:00', 'end_time', '10:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:40', 'end_time', '11:20'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '11:20', 'end_time', '12:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '12:00', 'end_time', '12:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '12:40', 'end_time', '13:20')
  ),
  true
) as regular_id \gset

-- FR-F02's standard Friday shortening.
select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'FRIDAY', 'Friday Shortened',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:35'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:35', 'end_time', '09:10')
  )
) as friday_id \gset

-- This FR's own: 6 periods of 30 minutes.
select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'RAMADAN', 'Ramadan Day',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:30'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:30', 'end_time', '09:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:00', 'end_time', '09:30'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '09:30', 'end_time', '10:00'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:00', 'end_time', '10:30'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '10:30', 'end_time', '11:00')
  )
) as ramadan_id \gset

-- Shorter still: a Friday that also falls inside Ramadan.
select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'RAMFRI', 'Ramadan Friday',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:25'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:25', 'end_time', '08:50')
  )
) as ramfri_id \gset

select public.create_bell_calendar_rule(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, :'friday_id'::uuid, 5::smallint
) as friday_rule_id \gset

-- The Ramadan window itself: an administrator-entered date range, no
-- weekday, precedence left to the function's own date-range default.
select public.create_bell_calendar_rule(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, :'ramadan_id'::uuid,
  null::smallint, '2027-02-18'::date, '2027-03-19'::date
) as ramadan_rule_id \gset

select is(
  (select precedence from public.bell_calendar_rule where id = :'ramadan_rule_id'::uuid),
  100::smallint,
  'a date-range rule defaults to precedence 100, a weekday rule to 50'
);

-- ── AC1: on a Ramadan Friday, Ramadan wins on precedence ──────────────

select is(extract(dow from date '2027-02-19')::int, 5, 'fixture sanity: 2027-02-19 really is a Friday');

select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-19'::date),
  :'ramadan_id'::uuid,
  'AC1: on a Ramadan Friday the Ramadan rule (precedence 100) beats the standard Friday rule (50)'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-18'::date),
  :'ramadan_id'::uuid,
  'the first day of the window resolves to the Ramadan template'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-04-02'::date),
  :'friday_id'::uuid,
  'a Friday outside the window still resolves to the standard Friday template'
);

-- ── AC4: the range ends and the default returns with no manual action ─

select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-03-19'::date),
  :'ramadan_id'::uuid,
  'AC4: the last day of the range is still inside the window'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-03-20'::date),
  :'regular_id'::uuid,
  'AC4: the day after the range resolves to the default template with no manual action'
);

-- ── layered: a Ramadan Friday rule (weekday AND date range) ───────────

select public.create_bell_calendar_rule(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, :'ramfri_id'::uuid,
  5::smallint, '2027-02-18'::date, '2027-03-19'::date, 110::smallint, 'Ramadan Jumma'
) as ramfri_rule_id \gset

select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-19'::date),
  :'ramfri_id'::uuid,
  'a rule carrying both a weekday and the Ramadan range wins on a Ramadan Friday'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-18'::date),
  :'ramadan_id'::uuid,
  'that layered rule does not apply to a non-Friday inside the window'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-04-02'::date),
  :'friday_id'::uuid,
  'that layered rule does not leak to a Friday outside the window'
);

-- ── AC5: overlapping ranges at equal precedence are rejected ──────────

select throws_ok(
  format(
    $$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L, null::smallint, '2027-03-01'::date, '2027-04-01'::date, 100::smallint) $$,
    :'campus_id', :'regular_id'
  ),
  'BELL_RULE_DATE_RANGE_OVERLAP',
  'AC5: a second date-range rule of equal precedence overlapping the first is rejected by the exclusion constraint'
);
select lives_ok(
  format(
    $$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L, null::smallint, '2027-03-20'::date, '2027-04-01'::date, 100::smallint) $$,
    :'campus_id', :'regular_id'
  ),
  'a date-range rule of equal precedence that starts the day after the first ends is accepted'
);
select is(
  (select count(*)::int from pg_constraint where conname = 'ex_bell_rule_no_ambiguity' and conrelid = 'public.bell_calendar_rule'::regclass),
  1,
  'ex_bell_rule_no_ambiguity is a real constraint on bell_calendar_rule'
);
select throws_ok(
  format(
    $$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L, null::smallint, '2027-06-01'::date, '2027-05-01'::date) $$,
    :'campus_id', :'regular_id'
  ),
  'BELL_RULE_DATE_ORDER_INVALID',
  'a range whose end precedes its start is rejected'
);

-- ── AC3 fixture: a section with 8 published slots inside the window ───

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_subject('PHY', 'Physics', 'فزکس') as physics_id \gset
select public.upsert_class_subject(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'physics_id'::uuid, 8::smallint);
select public.create_staff_teachable_subject(:'teacher_user_id'::uuid, :'physics_id'::uuid, :'class1_id'::uuid, :'class1_id'::uuid);

select public.create_timetable_version(:'campus_id'::uuid, :'session_id'::uuid, 'MORNING'::public.section_shift, 'Draft 1') as version_id \gset

select public.upsert_timetable_slot(:'version_id'::uuid, :'section_id'::uuid, 1::smallint, p::smallint, :'physics_id'::uuid, :'teacher_user_id'::uuid)
  from generate_series(1, 8) as p;

select public.publish_timetable(:'version_id'::uuid, '2027-02-01'::date);

-- ── AC2: the moon sighting shifts the start by one day ────────────────

select public.create_student(:'campus_id'::uuid, 'A Student', '2015-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrolment_id \gset

-- Marked directly rather than through save_attendance_register(): this
-- FR's AC is about a date in 2027, and the register's own lock/date
-- rules are not what is under test here — that the resolver never
-- touches an attendance row is.
reset role;
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status)
values (:'tenant_id', :'campus_id', :'session_id', :'section_id', :'enrolment_id', '2027-02-18'::date, 'present');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'girls_campus_id'), 'sub', :'owner_user_id')::text,
  true
);

select to_jsonb(a.*) as attendance_before
  from public.attendance_day a where a.enrolment_id = :'enrolment_id'::uuid and a.attendance_date = '2027-02-18'::date \gset

select public.update_bell_calendar_rule_dates(:'ramadan_rule_id'::uuid, '2027-02-19'::date, '2027-03-19'::date);

select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-18'::date),
  :'regular_id'::uuid,
  'AC2: after the Principal corrects date_from, 2027-02-18 resolves back to the regular template on the next request'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-19'::date),
  :'ramfri_id'::uuid,
  'AC2: the corrected window still starts on 2027-02-19'
);
select is(
  (select to_jsonb(a.*) from public.attendance_day a where a.enrolment_id = :'enrolment_id'::uuid and a.attendance_date = '2027-02-18'::date),
  :'attendance_before'::jsonb,
  'AC2: attendance already marked for 2027-02-18 is preserved byte-for-byte by the correction'
);

-- ── AC3: 8 published slots on a 6-period Ramadan day ──────────────────

select is(
  (select count(*)::int from public.bell_period where bell_template_id = :'ramadan_id'::uuid and period_no is not null),
  6,
  'fixture sanity: the Ramadan template really has 6 teaching periods'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-22'::date),
  :'ramadan_id'::uuid,
  'the Monday under test resolves to the 6-period Ramadan template'
);
select is(
  (select count(*)::int from public.timetable_slot where timetable_version_id = :'version_id'::uuid and weekday = 1),
  8,
  'AC3: all 8 slots survive in the published version — nothing is deleted by the override'
);
select is(
  (select count(*)::int from public.teacher_timetable(:'teacher_user_id'::uuid, '2027-02-22'::date) where weekday = 1),
  8,
  'AC3: the teacher''s day view still lists all 8 periods'
);
select isnt(
  (select start_time from public.teacher_timetable(:'teacher_user_id'::uuid, '2027-02-22'::date) where weekday = 1 and period_no = 6),
  null,
  'AC3: period 6 resolves to a real Ramadan clock time'
);
select is(
  (select count(*)::int from public.teacher_timetable(:'teacher_user_id'::uuid, '2027-02-22'::date) where weekday = 1 and period_no in (7, 8) and start_time is null),
  2,
  'AC3: periods 7 and 8 resolve to no clock time — rendered "Not held today", not deleted'
);

-- ── authorization and campus scoping ──────────────────────────────────

select throws_ok(
  format($$ select public.update_bell_calendar_rule_dates(%L, '2027-02-19'::date, '2027-03-19'::date) $$, :'friday_rule_id'),
  'BELL_RULE_NOT_DATE_RANGED',
  'the date correction refuses a weekday rule, which has no range to correct'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.update_bell_calendar_rule_dates(%L, '2027-02-19'::date, '2027-03-19'::date) $$, :'ramadan_rule_id'),
  'FORBIDDEN',
  'a subject teacher cannot shift the Ramadan window'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'girls_campus_id'), 'sub', :'principal_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.update_bell_calendar_rule_dates(%L, '2027-02-19'::date, '2027-03-19'::date) $$, :'ramadan_rule_id'),
  'FORBIDDEN',
  'a Principal scoped to another campus cannot shift this campus''s Ramadan window'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2027-02-22'::date),
  null,
  'the campus guard on resolve_bell_template still returns null for an out-of-scope campus'
);
select is(
  (select count(*)::int from public.bell_calendar_rule where id = :'ramadan_rule_id'::uuid),
  0,
  'RLS: a Principal scoped to another campus cannot see this campus''s Ramadan rule'
);

select * from finish();
rollback;
