-- pgTAP tests for FR-K26: automated fee reminder escalation.
begin;
select plan(24);

select public.provision_tenant('test-reminder-co', 'Reminder Co', 'owner@reminderco.test');
select id as tenant_id from public.tenant where slug = 'test-reminder-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-reminder-other', 'Other Reminder Co', 'owner@otherreminderco.test');
select id as other_tenant_id from public.tenant where slug = 'test-reminder-other' \gset

select set_config('t.campus', :'campus_id', false), set_config('t.session', :'session_id', false), set_config('t.class', :'class1_id', false);
create temp table kid (n int primary key, enrol_id uuid, student_id uuid, challan_id uuid);
grant all on kid to authenticated;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as section_id \gset
do $$
declare i int; v_stu uuid;
begin
  for i in 1..8 loop
    v_stu := public.create_student(current_setting('t.campus')::uuid, 'Reminder Kid ' || i, '2015-01-01'::date, 'male');
    insert into kid values (i, public.enrol_student((select id from public.class_section where campus_id = current_setting('t.campus')::uuid limit 1), v_stu), v_stu, null);
  end loop;
end $$;
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);

-- guardians: A has kids 1-3 (consolidation), B has kid 4 and prefers Urdu, C has kid 5 (paid mid-ladder), D has kid 6 (quiet hours), E has kid 7 (15-day task), kid 8 has no phone
select public.fn_find_or_create_guardian(p_name_en => 'Guardian A', p_phone_e164 => '+923001000001') as ga \gset
select public.fn_find_or_create_guardian(p_name_en => 'Guardian B', p_phone_e164 => '+923001000002') as gb \gset
select public.fn_find_or_create_guardian(p_name_en => 'Guardian C', p_phone_e164 => '+923001000003') as gc \gset
select public.fn_find_or_create_guardian(p_name_en => 'Guardian D', p_phone_e164 => '+923001000004') as gd \gset
select public.fn_find_or_create_guardian(p_name_en => 'Guardian E', p_phone_e164 => '+923001000005') as ge \gset
select public.fn_find_or_create_guardian(p_name_en => 'Guardian F') as gf \gset
select public.link_guardian((select student_id from kid where n = 1), :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 2), :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 3), :'ga'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 4), :'gb'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 5), :'gc'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 6), :'gd'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 7), :'ge'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian((select student_id from kid where n = 8), :'gf'::uuid, 'father'::public.guardian_relationship, true, true);
select public.seed_default_fee_reminder_rules(null) as seeded \gset
reset role;
update public.guardian set preferred_language = 'ur' where id = :'gb'::uuid;
update kid k set challan_id = c.id from public.fee_challan c where c.enrolment_id = k.enrol_id;
select current_date as run \gset

select is(:'seeded'::int, 3, 'the default ladder seeds three rungs');
select is((select count(*)::int from public.message_template where tenant_id = :'tenant_id' and code like 'fee_reminder%'), 2, 'AC: the wording lives in templates, not in code');
select ok((select bool_and(body_ur is not null) from public.message_template_version v join public.message_template t on t.id = v.template_id where t.tenant_id = :'tenant_id' and t.code like 'fee_reminder%'), 'with Urdu bodies stored as template text');
select is(has_function_privilege('authenticated', 'public.fees_reminder_escalation(date,uuid,timestamptz)', 'execute'), false, 'a client cannot run the escalation');

-- ── AC1/AC2: day-1 SMS, exactly once ──────────────────────────────────────
update public.fee_challan set due_date = :'run'::date - 1 where id = (select challan_id from kid where n = 4);
select public.fees_reminder_escalation(:'run'::date, :'tenant_id'::uuid) as r1 \gset
select is((select count(*)::int from public.message where tenant_id = :'tenant_id' and metadata ->> 'rung' = 'sms_d1'), 1, 'AC: a challan due yesterday queues exactly one SMS');
select is((select status from public.fee_reminder_log where challan_id = (select challan_id from kid where n = 4) and rung_code = 'sms_d1'), 'queued', 'AC: and a reminder log row records rung sms_d1');
select is((select recipient_phone from public.message where metadata ->> 'rung' = 'sms_d1' and tenant_id = :'tenant_id'), '+923001000002', 'to the primary guardian number');
select public.fees_reminder_escalation(:'run'::date, :'tenant_id'::uuid);
select is((select count(*)::int from public.message where tenant_id = :'tenant_id' and metadata ->> 'rung' = 'sms_d1'), 1, 'AC: rerunning the same day sends no second day-1 SMS');
select public.fees_reminder_escalation(:'run'::date + 1, :'tenant_id'::uuid);
select is((select count(*)::int from public.message where tenant_id = :'tenant_id' and metadata ->> 'rung' = 'sms_d1'), 1, 'AC: nor the next day');
select ok((select body like '%محترم%' from public.message where metadata ->> 'rung' = 'sms_d1' and tenant_id = :'tenant_id'), 'the Urdu-preferring guardian gets the Urdu template body');
select ok((select body like '%Reminder Kid 4%' and body like '%3,000%' or body like '%5,000%' from public.message where metadata ->> 'rung' = 'sms_d1' and tenant_id = :'tenant_id'), 'with the child and the amount filled in');

-- ── AC5: one consolidated WhatsApp for three children ─────────────────────
update public.fee_challan set due_date = :'run'::date - 7 where id in (select challan_id from kid where n in (1, 2, 3));
select public.fees_reminder_escalation(:'run'::date, :'tenant_id'::uuid);
select is((select count(*)::int from public.message where tenant_id = :'tenant_id' and metadata ->> 'rung' = 'wa_d7' and recipient_phone = '+923001000001'), 1, 'AC: a guardian with 3 overdue children gets ONE day-7 WhatsApp');
select ok((select body like '%Reminder Kid 1%' and body like '%Reminder Kid 2%' and body like '%Reminder Kid 3%' from public.message where metadata ->> 'rung' = 'wa_d7' and recipient_phone = '+923001000001'), 'AC: listing all three children');
select is((select count(distinct message_id)::int from public.fee_reminder_log where rung_code = 'wa_d7' and guardian_id = :'ga'::uuid), 1, 'the three log rows share that one message');
select is((select count(*)::int from public.fee_reminder_log where rung_code = 'wa_d7' and guardian_id = :'ga'::uuid), 3, 'one log row per challan');

-- ── AC3: paid mid-ladder halts it ─────────────────────────────────────────
update public.fee_challan set due_date = :'run'::date - 7 where id = (select challan_id from kid where n = 5);
insert into public.fee_reminder_log (tenant_id, campus_id, challan_id, rung_code, guardian_id, channel, status)
select :'tenant_id', :'campus_id', challan_id, 'sms_d1', :'gc'::uuid, 'sms', 'queued' from kid where n = 5;
update public.fee_challan set status = 'paid' where id = (select challan_id from kid where n = 5);
select public.fees_reminder_escalation(:'run'::date, :'tenant_id'::uuid);
select is((select status from public.fee_reminder_log where challan_id = (select challan_id from kid where n = 5) and rung_code = 'wa_d7'), 'halted', 'AC: a challan paid before day 7 has its ladder marked halted');
select is((select count(*)::int from public.message where recipient_phone = '+923001000003' and tenant_id = :'tenant_id'), 0, 'AC: and no WhatsApp is sent');

-- ── AC4: quiet hours ──────────────────────────────────────────────────────
update public.fee_challan set due_date = :'run'::date - 1 where id = (select challan_id from kid where n = 6);
select public.fees_reminder_escalation(:'run'::date, :'tenant_id'::uuid, ((:'run'::date)::timestamp + time '03:00') at time zone 'Asia/Karachi');
select is((select to_char(scheduled_at at time zone 'Asia/Karachi', 'HH24:MI') from public.message where recipient_phone = '+923001000004'), '08:00', 'AC: a message created at 03:00 is queued but scheduled for 08:00');
select is((select status::text from public.message where recipient_phone = '+923001000004'), 'queued', 'and it is queued, not sent');

-- ── rung 3 is a task; reachable-guardian handling ─────────────────────────
update public.fee_challan set due_date = :'run'::date - 15 where id = (select challan_id from kid where n = 7);
update public.fee_challan set due_date = :'run'::date - 1 where id = (select challan_id from kid where n = 8);
select public.fees_reminder_escalation(:'run'::date, :'tenant_id'::uuid);
select is((select count(*)::int from public.fee_follow_up_task where guardian_id = :'ge'::uuid and status = 'open'), 1, 'day 15 opens a phone-call task rather than another message');
select is((select status from public.fee_reminder_log where challan_id = (select challan_id from kid where n = 8) and rung_code = 'sms_d1'), 'skipped_no_guardian_phone', 'a guardian with no phone is logged as skipped, not silently dropped');

-- ── scope ─────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.fee_reminder_log) >= 8, 'the accountant reads the reminder log');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.fee_reminder_log) + (select count(*)::int from public.fee_reminder_rule) + (select count(*)::int from public.fee_follow_up_task), 0, 'another school sees none of it');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.seed_default_fee_reminder_rules(null) $$, 'FORBIDDEN', 'a teacher cannot configure the ladder');
reset role;

select * from finish();
rollback;
