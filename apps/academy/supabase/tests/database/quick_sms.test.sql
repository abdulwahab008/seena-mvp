begin;
select plan(9);

select public.provision_tenant('test-quick-sms', 'Quick SMS Co', 'owner@quicksms.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
values (:'tenant_id', :'campus_id', :'session_id', :'class9', 'A', 40) returning id as sec \gset

insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender) values
  (:'tenant_id', :'campus_id', 'QS-1', 'Sibling One', '2012-01-01', 'female'),
  (:'tenant_id', :'campus_id', 'QS-2', 'Sibling Two', '2013-01-01', 'male'),
  (:'tenant_id', :'campus_id', 'QS-3', 'No Phone', '2012-01-01', 'male');
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select :'tenant_id', :'campus_id', :'session_id', id, :'class9', :'sec' from public.student where tenant_id = :'tenant_id';
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id', 'Shared Mother', '+923001110001') returning id as mum \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', id, :'mum', 'mother', true, true from public.student where tenant_id = :'tenant_id' and gr_number in ('QS-1', 'QS-2');

insert into public.staff (tenant_id, campus_id, employee_code, cnic, gender, full_name) values
  (:'tenant_id', :'campus_id', 'QS-S1', '42101-6666666-1', 'female', 'Staff With Mobile'),
  (:'tenant_id', :'campus_id', 'QS-S2', '42101-6666666-2', 'male', 'Staff Without Mobile');
insert into public.staff_private_contact (staff_id, mobile)
select id, '0300-2223334' from public.staff where tenant_id = :'tenant_id' and employee_code = 'QS-S1';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'receptionist', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.queue_quick_sms(:'campus_id', 'section', :'sec', null, 'School closed tomorrow.') - 'batch_id', '{"queued": 1, "skipped": 1}'::jsonb,
  'one message to the section''s parents: siblings share a number, a student with no number is skipped');
select is(public.queue_quick_sms(:'campus_id', 'staff', null, null, 'Staff meeting at 2pm.') - 'batch_id', '{"queued": 1, "skipped": 1}'::jsonb,
  'all staff: the one with a mobile is queued');
select is(public.queue_quick_sms(:'campus_id', 'numbers', null, array['03001234567', '+92 300 1234567', 'abc'], 'Hello') - 'batch_id', '{"queued": 1, "skipped": 1}'::jsonb,
  'typed numbers are normalised and de-duplicated; a bad one is skipped');
select throws_ok(format($$ select public.queue_quick_sms(%L, 'numbers', null, array['03001234567'], '   ') $$, :'campus_id'), '22023', 'BODY_INVALID', 'an empty message is refused');

reset role;
select is((select count(*)::int from public.message where tenant_id = :'tenant_id' and metadata ->> 'template' = 'quick_sms' and status = 'queued' and channel = 'sms'), 3,
  'everything lands in the outbox as queued SMS');
select is((select recipient_phone from public.message where tenant_id = :'tenant_id' and recipient_type = 'staff'), '+923002223334', 'the staff mobile is stored in E.164');
select is((select sum(total_count)::int from public.message_batch where tenant_id = :'tenant_id' and title = 'Quick SMS'), 3, 'each send is one outbox batch with its count');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.queue_quick_sms(%L, 'staff', null, null, 'x') $$, :'campus_id'), '42501', 'FORBIDDEN', 'a teacher cannot send a quick SMS');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.queue_quick_sms(%L, 'staff', null, null, 'x') $$, :'campus_id'), '42501', 'FORBIDDEN', 'nor can a parent');

select * from finish();
rollback;
