-- pgTAP tests for FR-G12: automated absentee SMS to parent.
begin;
select plan(33);

select public.provision_tenant('test-absentee-sms-co', 'Absentee SMS Co', 'owner@absenteesmsco.test');
select id as tenant_id from public.tenant where slug = 'test-absentee-sms-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b \gset

select public.create_student(:'campus_id'::uuid, 'Absentee One', '2015-01-01'::date, 'male') as s1_id \gset
select public.enrol_student(:'section_a'::uuid, :'s1_id'::uuid) as s1_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Absentee Two', '2015-01-01'::date, 'female') as s2_id \gset
select public.enrol_student(:'section_a'::uuid, :'s2_id'::uuid) as s2_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Absentee Three No Phone', '2015-01-01'::date, 'male') as s3_id \gset
select public.enrol_student(:'section_a'::uuid, :'s3_id'::uuid) as s3_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Absentee Four No Guardian', '2015-01-01'::date, 'female') as s4_id \gset
select public.enrol_student(:'section_a'::uuid, :'s4_id'::uuid) as s4_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Present Five', '2015-01-01'::date, 'male') as s5_id \gset
select public.enrol_student(:'section_a'::uuid, :'s5_id'::uuid) as s5_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Never Marked Six', '2015-01-01'::date, 'female') as s6_id \gset
select public.enrol_student(:'section_b'::uuid, :'s6_id'::uuid) as s6_enrol \gset
-- section_register_submitted() is point-in-time (joined_on/left_on),
-- not "currently active" — enrol_student() always sets joined_on to
-- today, so this backdate is what makes S6 count as part of section
-- B's expected roster on the past test dates below.
reset role;
update public.enrolment set joined_on = current_date - 200 where id = :'s6_enrol'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- guardians: S1 (english, has phone), S2 (urdu, has phone), S3 (has a
-- guardian row but no phone on file), S4 has no guardian row at all.
reset role;
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id'::uuid, 'Guardian One', '+923001234561') returning id as g1_id \gset
insert into public.guardian (tenant_id, name_en, name_ur, phone_e164) values (:'tenant_id'::uuid, 'Guardian Two', 'سرپرست دو', '+923001234562') returning id as g2_id \gset
insert into public.guardian (tenant_id, name_en) values (:'tenant_id'::uuid, 'Guardian Three No Phone') returning id as g3_id \gset

insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id'::uuid, :'s1_id'::uuid, :'g1_id'::uuid, 'father', true, true);
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id'::uuid, :'s2_id'::uuid, :'g2_id'::uuid, 'mother', true, true);
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
values (:'tenant_id'::uuid, :'s3_id'::uuid, :'g3_id'::uuid, 'father', true, true);

select (current_date - 5) as att_date \gset

-- section A's register was fully submitted: every active student gets a
-- row, present included — matches what rpc_bulk_mark_attendance()
-- actually persists today (see migration header). Section B gets none.
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source) values
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s1_enrol'::uuid, :'att_date'::date, 'absent', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s2_enrol'::uuid, :'att_date'::date, 'absent', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s3_enrol'::uuid, :'att_date'::date, 'absent', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s4_enrol'::uuid, :'att_date'::date, 'absent', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s5_enrol'::uuid, :'att_date'::date, 'present', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── AC5 groundwork: section B never marked ─────────────────────────
select is(
  (select count(*)::int from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date) where enrolment_id = :'s6_enrol'::uuid),
  0,
  'AC5: a student in a never-marked section is not a candidate absentee'
);
select is(
  (select count(*)::int from public.sections_not_marked(:'campus_id'::uuid, :'att_date'::date) where section_id = :'section_b'::uuid),
  1,
  'AC5: the never-marked section appears on the not-marked list'
);

-- ── AC1: candidate set carries the right joined data ───────────────
select is(
  (select count(*)::int from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date)),
  4,
  'AC1: 4 absentee candidates in section A (S1-S4), S5 (present) excluded'
);
select is(
  (select gr_number from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date) where enrolment_id = :'s1_enrol'::uuid),
  (select gr_number from public.student where id = :'s1_id'::uuid),
  'AC1: the candidate row carries the real GR number'
);
select is(
  (select section_label from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date) where enrolment_id = :'s1_enrol'::uuid),
  'Class 1 · A',
  'AC1: the candidate row carries the class-section label'
);

-- ── AC2: a student corrected to present before the job runs is
--    excluded entirely — no special-case code, just a live re-read ──
reset role;
update public.attendance_day set status = 'present' where enrolment_id = :'s1_enrol'::uuid and attendance_date = :'att_date'::date;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date) where enrolment_id = :'s1_enrol'::uuid),
  0,
  'AC2: a student corrected to present before dispatch is no longer a candidate'
);

-- ── dispatch: S1 excluded (corrected), S2 queued, S3/S4 skipped ────
select public.dispatch_absentee_notifications(:'campus_id'::uuid, :'att_date'::date) as result1 \gset
select is(
  (:'result1'::jsonb ->> 'queued')::int,
  1,
  'dispatch: exactly 1 message queued (S2 — S3/S4 have no usable phone)'
);
select is(
  (:'result1'::jsonb ->> 'skipped_no_contact')::int,
  2,
  'dispatch: 2 skipped_no_contact (S3 no phone, S4 no guardian at all)'
);
select is(
  (:'result1'::jsonb ->> 'sections_not_marked')::int,
  1,
  'dispatch: 1 section (B) reported not marked'
);
select is(
  (select count(*)::int from public.attendance_notification where enrolment_id = :'s1_enrol'::uuid),
  0,
  'AC2: no attendance_notification row was ever written for the corrected student'
);
select is(
  (select status from public.attendance_notification where enrolment_id = :'s2_enrol'::uuid)::text,
  'queued',
  'AC1: the absentee with a phone on file is queued'
);
select is(
  (select language from public.attendance_notification where enrolment_id = :'s2_enrol'::uuid)::text,
  'ur',
  'the guardian with an Urdu name gets the Urdu template'
);
select is(
  (select recipient_msisdn from public.attendance_notification where enrolment_id = :'s2_enrol'::uuid),
  '+923001234562',
  'AC1: the queued row carries the real guardian phone number'
);
select ok(
  (select cost_paisa from public.attendance_notification where enrolment_id = :'s2_enrol'::uuid) > 0,
  'a queued message has a real, non-zero computed cost'
);

-- ── AC4: both no-contact reasons land on the exception status ──────
select is(
  (select status from public.attendance_notification where enrolment_id = :'s3_enrol'::uuid)::text,
  'skipped_no_contact',
  'AC4: a guardian with no phone on file is recorded skipped_no_contact'
);
select is(
  (select status from public.attendance_notification where enrolment_id = :'s4_enrol'::uuid)::text,
  'skipped_no_contact',
  'AC4: a student with no guardian at all is recorded skipped_no_contact'
);
select is(
  (select cost_paisa from public.attendance_notification where enrolment_id = :'s3_enrol'::uuid),
  0,
  'a skipped message never incurs cost'
);

-- ── AC3: re-running the same day is a pure no-op, no duplicates ────
select is(
  (select count(*)::int from public.attendance_notification where campus_id = :'campus_id'::uuid and notification_date = :'att_date'::date),
  3,
  'sanity: 3 rows exist after the first dispatch (S2 queued, S3/S4 skipped)'
);
select public.dispatch_absentee_notifications(:'campus_id'::uuid, :'att_date'::date) as result2 \gset
select is(
  (:'result2'::jsonb ->> 'queued')::int,
  0,
  'AC3: a same-day re-run queues nothing new'
);
select is(
  (select count(*)::int from public.attendance_notification where campus_id = :'campus_id'::uuid and notification_date = :'att_date'::date),
  3,
  'AC3: the unique constraint on (enrolment_id, notification_date, channel) prevented any duplicate row'
);

-- ── daily cost cap: a low cap defers the rest to a later re-run ────
select (current_date - 6) as cap_date \gset
select public.create_student(:'campus_id'::uuid, 'Cap Seven', '2015-01-01'::date, 'male') as s7_id \gset
select public.enrol_student(:'section_a'::uuid, :'s7_id'::uuid) as s7_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Cap Eight', '2015-01-01'::date, 'female') as s8_id \gset
select public.enrol_student(:'section_a'::uuid, :'s8_id'::uuid) as s8_enrol \gset

reset role;
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id'::uuid, 'Guardian Seven', '+923001234567') returning id as g7_id \gset
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id'::uuid, 'Guardian Eight', '+923001234568') returning id as g8_id \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values (:'tenant_id'::uuid, :'s7_id'::uuid, :'g7_id'::uuid, 'father', true, true);
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing) values (:'tenant_id'::uuid, :'s8_id'::uuid, :'g8_id'::uuid, 'mother', true, true);
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source) values
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s7_enrol'::uuid, :'cap_date'::date, 'absent', 'web'),
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_a'::uuid, :'s8_enrol'::uuid, :'cap_date'::date, 'absent', 'web');
update public.campus set daily_sms_cap_paisa = 100 where id = :'campus_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.dispatch_absentee_notifications(:'campus_id'::uuid, :'cap_date'::date) as cap_result1 \gset
select is(
  (:'cap_result1'::jsonb ->> 'queued')::int,
  1,
  'daily cap: only 1 of 2 absentees is queued once the campus budget is exhausted'
);

-- Cap raised to 200, not unlimited: S7 already has a real cost of 100
-- on file, S8 needs another 100. A re-run must correctly see the TRUE
-- remaining budget (200 - 100 = 100) rather than double-counting S7's
-- own cost again while re-evaluating it (the exact race the "skip if
-- already exists, before touching any cost/cap logic" fix guards
-- against) — with the fix, S8 fits exactly at the 200 boundary.
reset role;
update public.campus set daily_sms_cap_paisa = 200 where id = :'campus_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.dispatch_absentee_notifications(:'campus_id'::uuid, :'cap_date'::date) as cap_result2 \gset
select is(
  (:'cap_result2'::jsonb ->> 'queued')::int,
  1,
  'daily cap: raising the cap and re-running picks up exactly the deferred absentee'
);
select is(
  (select count(*)::int from public.attendance_notification where campus_id = :'campus_id'::uuid and notification_date = :'cap_date'::date),
  2,
  'daily cap: both absentees are now queued, with no duplicate for the one queued first'
);
select is(
  (select sum(cost_paisa)::int from public.attendance_notification where campus_id = :'campus_id'::uuid and notification_date = :'cap_date'::date),
  200,
  'daily cap: total recorded spend is exactly the real sum, not inflated by re-evaluating the already-queued absentee'
);

-- ── partial register submission (not just zero rows) still counts as
--    "not marked" — a direct save_attendance_register() call with a
--    partial marks array must not be mistaken for a full submission ──
select public.create_student(:'campus_id'::uuid, 'Partial Nine', '2015-01-01'::date, 'male') as s9_id \gset
select public.enrol_student(:'section_b'::uuid, :'s9_id'::uuid) as s9_enrol \gset
select public.create_student(:'campus_id'::uuid, 'Partial Ten', '2015-01-01'::date, 'female') as s10_id \gset
select public.enrol_student(:'section_b'::uuid, :'s10_id'::uuid) as s10_enrol \gset
select (current_date - 7) as partial_date \gset
-- Only ONE of section B's several enrolments active as of partial_date
-- gets a row — this is what a raw, partial save_attendance_register()
-- call leaves behind, deliberately not going through
-- rpc_bulk_mark_attendance()'s full expansion.
reset role;
update public.enrolment set joined_on = current_date - 200 where id in (:'s9_enrol'::uuid, :'s10_enrol'::uuid);
insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status, source) values
  (:'tenant_id'::uuid, :'campus_id'::uuid, :'session_id'::uuid, :'section_b'::uuid, :'s9_enrol'::uuid, :'partial_date'::date, 'absent', 'web');
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.absentees_for_date(:'campus_id'::uuid, :'partial_date'::date) where enrolment_id = :'s9_enrol'::uuid),
  0,
  'a partially-submitted register (1 of 2 active students marked) is treated as not submitted, not as one real absence'
);
select is(
  (select count(*)::int from public.sections_not_marked(:'campus_id'::uuid, :'partial_date'::date) where section_id = :'section_b'::uuid),
  1,
  'the partially-submitted section appears on the not-marked list'
);

-- ── the Urdu student name is available for the SMS body, distinct
--    from the English name shown in the office's own UI ─────────────
reset role;
update public.student set name_ur = 'طالبہ دو' where id = :'s2_id'::uuid;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select student_name_ur from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date) where enrolment_id = :'s2_enrol'::uuid),
  'طالبہ دو',
  'the candidate row carries the student''s Urdu name when set, for the Urdu SMS body to use'
);

-- ── validation / tenant isolation ──────────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format('select public.dispatch_absentee_notifications(%L, %L)', :'campus_id', :'att_date'),
  'FORBIDDEN',
  'a role with no attendance access cannot trigger dispatch'
);

-- notif_campus_read's own OR has two branches: super_admin/owner, or
-- same-campus for anyone else. Every read assertion so far ran as
-- 'owner', which only ever exercises the first branch — this librarian
-- (same tenant, same campus_ids, forbidden from dispatch above) is what
-- proves the second branch actually grants read access on its own.
select ok(
  (select count(*)::int from public.attendance_notification where campus_id = :'campus_id'::uuid and notification_date = :'att_date'::date) > 0,
  'a non-admin, same-campus role can read attendance_notification via RLS even though it cannot dispatch'
);

reset role;
select public.provision_tenant('test-absentee-sms-other-co', 'Absentee SMS Other Co', 'owner@absenteesmsotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-absentee-sms-other-co' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json)::text,
  true
);
select throws_ok(
  format('select public.dispatch_absentee_notifications(%L, %L)', :'campus_id', :'att_date'),
  'CAMPUS_NOT_FOUND',
  'AC/defense-in-depth: another tenant cannot dispatch against this tenant''s campus'
);
select is(
  (select count(*)::int from public.attendance_notification),
  0,
  'AC/defense-in-depth: another tenant''s owner sees zero attendance_notification rows via RLS'
);

-- ── absentees_for_date() and sections_not_marked() are independently
--    granted to authenticated and SECURITY DEFINER (bypasses RLS) —
--    each must refuse a foreign tenant's campus_id on its own, not
--    merely rely on dispatch_absentee_notifications()'s own check ────
select is(
  (select count(*)::int from public.absentees_for_date(:'campus_id'::uuid, :'att_date'::date)),
  0,
  'defense-in-depth: another tenant cannot read this tenant''s absentee candidates via a direct RPC call'
);
select is(
  (select count(*)::int from public.sections_not_marked(:'campus_id'::uuid, :'att_date'::date)),
  0,
  'defense-in-depth: another tenant cannot read this tenant''s not-marked sections via a direct RPC call'
);

select * from finish();
rollback;
