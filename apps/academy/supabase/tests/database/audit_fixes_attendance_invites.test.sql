-- pgTAP tests for the 6 Nov 2026 browser-audit fixes: school time zone (BUG-05), default
-- attendance policy (BUG-03), class in-charge rights for any teacher (BUG-04) and guardian
-- portal invites reaching the message outbox (BUG-02).
begin;
select plan(10);

select is(current_setting('TimeZone'), 'Asia/Karachi', 'BUG-05: database sessions run on Pakistan time');

select public.provision_tenant('test-audit-fixes-co', 'Audit Fixes Co', 'owner@auditfixes.test');
select id as tenant_id from public.tenant where slug = 'test-audit-fixes-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select is(
  (select count(*)::int from public.attendance_policy where campus_id = :'campus_id'::uuid and session_id = :'session_id'::uuid),
  1,
  'BUG-03: a new school has an attendance policy for its first campus and session'
);
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'B2', 'Second Campus') returning id as campus2_id \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
values (:'tenant_id', :'campus2_id', '2026-27 B', '2026-04-01', '2027-03-31', false, 'planned') returning id as session2_id \gset
select is(
  (select count(*)::int from public.attendance_policy where campus_id = :'campus2_id'::uuid and session_id = :'session2_id'::uuid),
  1,
  'BUG-03: a session added later gets its campus policy too'
);

select gen_random_uuid() as teacher_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_id', 'subject@auditfixes.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'teacher_id', :'tenant_id', 'subject_teacher', 'Subject Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'B', 40) as section_b_id \gset
select public.assign_class_teacher(:'section_id'::uuid, :'teacher_id'::uuid, current_date - 30);
select public.create_student(:'campus_id'::uuid, 'Audit Kid', '2019-01-01'::date, 'male') as student_id \gset
select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset
select public.create_student(:'campus_id'::uuid, 'Other Kid', '2019-01-01'::date, 'female') as student_b_id \gset
select public.enrol_student(:'section_b_id'::uuid, :'student_b_id'::uuid) as enrol_b_id \gset
select public.fn_find_or_create_guardian(p_name_en => 'Audit Parent', p_phone_e164 => '+923335550101') as guardian_id \gset
select public.link_guardian(:'student_id'::uuid, :'guardian_id'::uuid, 'father'::public.guardian_relationship, true, true);

select is(public.is_attendance_locked(:'section_id'::uuid, current_date), false, 'BUG-03: today''s register is open with the default policy');

-- A subject teacher assigned as in-charge.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_id')::text, true);
select lives_ok(
  format($$ select public.save_attendance_register(%L, current_date, %L::jsonb, now(), 'web'::public.student_attendance_source, now()) $$,
         :'section_id', json_build_array(json_build_object('enrolment_id', :'enrol_id', 'status', 'present'))::text),
  'BUG-04: the in-charge subject teacher can save their section''s register'
);
select throws_ok(
  format($$ select public.save_attendance_register(%L, current_date, %L::jsonb, now(), 'web'::public.student_attendance_source, now()) $$,
         :'section_b_id', json_build_array(json_build_object('enrolment_id', :'enrol_b_id', 'status', 'present'))::text),
  '42501', null,
  'BUG-04: but not a section they are not in charge of'
);
select lives_ok(
  format($$ select public.request_attendance_correction(%L, current_date - 3, 'absent'::public.student_attendance_status, 'Was sent home sick in the morning') $$, :'enrol_id'),
  'BUG-04: and can request a correction for it'
);

-- Guardian invite reaches the outbox.
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.send_guardian_invite(:'guardian_id'::uuid, 'whatsapp', 'https://school.example') as invite \gset
select is((:'invite'::jsonb ->> 'queued')::boolean, true, 'BUG-02: a WhatsApp invite is queued');
reset role;
select ok(
  (select body like '%https://school.example/guardian/activate/' || (:'invite'::jsonb ->> 'token') || '%' and channel = 'whatsapp' and status = 'queued'
     from public.message where id = (:'invite'::jsonb ->> 'message_id')::uuid),
  'BUG-02: the queued message carries the activation link'
);
select is(
  (select count(*)::int from public.message where recipient_id = :'guardian_id'::uuid),
  1,
  'BUG-02: exactly one message per invite'
);

select * from finish();
rollback;
