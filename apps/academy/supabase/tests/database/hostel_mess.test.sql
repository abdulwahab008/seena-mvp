-- pgTAP tests for FR-Q05: weekly mess menu and mess-off days.
begin;
select plan(23);

select public.provision_tenant('test-mess-co', 'Mess Co', 'owner@mess.test');
select id as tenant_id from public.tenant where slug = 'test-mess-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-mess-other', 'Other Mess Co', 'owner@othermess.test');
select id as other_tenant_id from public.tenant where slug = 'test-mess-other' \gset

select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as stranger_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'prin_uid', 'p@mess.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'par@mess.test', 'authenticated', 'authenticated', 'x'),
  (:'stranger_uid', 'x@mess.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'prin_uid', :'tenant_id', 'principal', 'Principal');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 40) as section_id \gset
select public.create_hostel_block(:'campus_id'::uuid, 'IQ', 'Iqbal Block', 'male', 2, 4) as iq \gset
select public.create_student(:'campus_id'::uuid, 'Boarder One', '2012-01-01'::date, 'male') as s1 \gset
select public.create_student(:'campus_id'::uuid, 'Boarder Two', '2012-01-01'::date, 'male') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid);
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid);
select public.allocate_bed(:'s1'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B1'), '2026-01-05');
select public.allocate_bed(:'s2'::uuid, (select id from public.hostel_bed where bed_code = 'IQ-101-B2'), '2026-01-05');

reset role;
insert into public.guardian (tenant_id, name_en, auth_user_id, preferred_language) values (:'tenant_id', 'Parent One', :'parent_uid', 'ur');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', :'s1'::uuid, id, 'father', true, true from public.guardian where auth_user_id = :'parent_uid';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- AC1: a week of 21 slots, English and Urdu, published with a timestamp.
select public.save_mess_menu(:'campus_id'::uuid, '2026-08-03', (
  select jsonb_agg(jsonb_build_object('day', d, 'meal', m, 'items', m || ' day ' || d, 'items_ur', 'اردو ' || m || ' ' || d))
    from generate_series(1, 7) d, unnest(array['breakfast', 'lunch', 'dinner']) m where not (d = 7 and m = 'dinner'))) as saved \gset
select is(:'saved'::int, 20, 'twenty slots saved so far');
select throws_ok(format($$ select public.publish_mess_menu(%L, '2026-08-03') $$, :'campus_id'), 'MENU_INCOMPLETE', 'AC1: a week with a missing slot cannot be published');
select public.save_mess_menu(:'campus_id'::uuid, '2026-08-03', '[{"day": 7, "meal": "dinner", "items": "Biryani", "items_ur": "بریانی"}]'::jsonb);
select is((select count(*) from public.hostel_mess_menu where week_start = '2026-08-03'), 21::bigint, 'AC1: the week now has all 21 meal slots');
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_mess_menu), 0::bigint, 'a parent sees nothing while the menu is a draft');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.publish_mess_menu(:'campus_id'::uuid, '2026-08-03') as published_at \gset
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_mess_menu where week_start = '2026-08-03'), 21::bigint, 'AC1: once published, the parent sees all 21 slots');
select ok((select bool_and(items_ur is not null) and count(distinct published_at) = 1 from public.hostel_mess_menu where week_start = '2026-08-03'), 'AC1: each with Urdu text and the same publish timestamp');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_mess_menu(%L, '2026-08-03', '[{"day": 1, "meal": "lunch", "items": "Changed"}]'::jsonb) $$, :'campus_id'), 'MENU_PUBLISHED', 'a published week cannot be silently rewritten');

-- AC2: an approved mess-off of 10-14 August takes billable days from 31 to 26.
select is(public.billable_mess_days(:'s1'::uuid, '2026-08-01'), 31, 'AC2: a full August is 31 billable mess days');
select public.record_mess_off(:'s1'::uuid, '2026-08-10', '2026-08-14', 'Home for the break') as off1 \gset
select is(public.billable_mess_days(:'s1'::uuid, '2026-08-15'), 26, 'AC2: an approved mess-off of 10 to 14 August leaves 26 billable days');
select is(public.billable_mess_days(:'s2'::uuid, '2026-08-01'), 31, 'another student''s count is unaffected');

-- AC4: overlapping mess-off is refused by the exclusion constraint.
select throws_ok(format($$ select public.record_mess_off(%L, '2026-08-12', '2026-08-16') $$, :'s1'), 'MESS_OFF_OVERLAP', 'AC4: a second mess-off overlapping an approved one is rejected');
reset role;
select throws_ok(format($$ insert into public.hostel_mess_off (tenant_id, campus_id, student_id, starts_on, ends_on, status, approved_by, approved_at) values (%L, %L, %L, '2026-08-14', '2026-08-20', 'approved', %L, now()) $$, :'tenant_id', :'campus_id', :'s1', :'prin_uid'), '23P01', null, 'AC4: the exclusion constraint itself rejects the overlap (touching on 14 August counts)');
select lives_ok(format($$ insert into public.hostel_mess_off (tenant_id, campus_id, student_id, starts_on, ends_on, status, approved_by, approved_at) values (%L, %L, %L, '2026-08-15', '2026-08-16', 'approved', %L, now()) $$, :'tenant_id', :'campus_id', :'s1', :'prin_uid'), 'the next day is free');
delete from public.hostel_mess_off where starts_on = '2026-08-15';

-- AC3: notice period for a parent's request.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.request_mess_off(%L, app.fn_karachi_today() + 1, app.fn_karachi_today() + 3, 'Eid') $$, :'s1'), 'NOTICE_PERIOD_NOT_MET', 'AC3: a request starting in less than the 24-hour notice period is refused with NOTICE_PERIOD_NOT_MET');
select lives_ok(format($$ select public.request_mess_off(%L, app.fn_karachi_today() + 5, app.fn_karachi_today() + 7, 'Cousin''s wedding') $$, :'s1'), 'AC3: a request with enough notice is accepted');
select is((select status::text from public.hostel_mess_off where starts_on = app.fn_karachi_today() + 5), 'pending', 'and waits for approval');
select throws_ok(format($$ select public.request_mess_off(%L, app.fn_karachi_today() + 20, app.fn_karachi_today() + 22) $$, :'s2'), 'FORBIDDEN', 'a parent cannot request for someone else''s child');
select public.billable_mess_days(:'s1'::uuid, app.fn_karachi_today() + 5) as billable_pending \gset
select is(:'billable_pending'::int > 0, true, 'a pending request does not remove billable days yet');

-- Approval makes it count; the notice period is a tenant setting.
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.decide_mess_off((select id from public.hostel_mess_off where starts_on = app.fn_karachi_today() + 5), true);
select is((select status::text from public.hostel_mess_off where starts_on = app.fn_karachi_today() + 5), 'approved', 'the Principal approves the request');
select is(public.billable_mess_days(:'s1'::uuid, app.fn_karachi_today() + 5),
  :'billable_pending'::int - (select count(*)::int from generate_series(app.fn_karachi_today() + 5, app.fn_karachi_today() + 7, interval '1 day') g
                               where date_trunc('month', g) = date_trunc('month', (app.fn_karachi_today() + 5)::timestamp)),
  'once approved, its days leave the billable count');
select public.set_hostel_setting('hostel.mess_notice_hours', '0'::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select lives_ok(format($$ select public.request_mess_off(%L, app.fn_karachi_today() + 1, app.fn_karachi_today() + 1, 'Short notice') $$, :'s1'), 'with the notice period set to 0 hours, tomorrow is allowed');

-- Holiday calendar: when holidays are not billable they come off the count too.
reset role;
insert into public.holiday_calendar (tenant_id, campus_id, holiday_date, name) values (:'tenant_id', null, '2026-08-20', 'Test holiday'), (:'tenant_id', null, '2026-08-12', 'Holiday inside the mess-off');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_hostel_setting('hostel.mess_holidays_billable', 'false'::jsonb);
select is(public.billable_mess_days(:'s1'::uuid, '2026-08-01'), 25, 'with holidays not billable the 20th comes off too (26 -> 25; the 12th is already off)');

select set_config('request.jwt.claims', json_build_object('sub', :'stranger_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'principal', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.hostel_mess_off), 0::bigint, 'another school sees no mess-offs');

select * from finish();
rollback;
