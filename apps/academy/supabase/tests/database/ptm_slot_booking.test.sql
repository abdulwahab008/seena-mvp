-- pgTAP tests for FR-N11: PTM slot booking.
begin;
select plan(32);

select public.provision_tenant('test-ptm-co', 'PTM Co', 'owner@ptm.test');
select id as tenant_id from public.tenant where slug = 'test-ptm-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-ptm-other', 'Other PTM Co', 'owner@otherptm.test');
select id as other_tenant_id from public.tenant where slug = 'test-ptm-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as ct_uid \gset
select gen_random_uuid() as t3_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@ptm.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@ptm.test', 'authenticated', 'authenticated', 'x'),
  (:'ct_uid', 'ct@ptm.test', 'authenticated', 'authenticated', 'x'), (:'t3_uid', 't3@ptm.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'ct_uid', :'tenant_id', 'class_teacher', 'Miss Class Teacher'), (:'t3_uid', :'tenant_id', 'class_teacher', 'Mr Unrelated');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
select public.create_student(:'campus_id'::uuid, 'PTM Kid One', '2015-01-01'::date, 'male') as c1 \gset
select public.enrol_student(:'sec'::uuid, :'c1'::uuid);
select public.create_student(:'campus_id'::uuid, 'PTM Kid Two', '2015-02-01'::date, 'female') as c2 \gset
select public.enrol_student(:'sec'::uuid, :'c2'::uuid);
select public.create_student(:'campus_id'::uuid, 'PTM Kid Three', '2015-03-01'::date, 'male') as c3 \gset
select public.enrol_student(:'sec'::uuid, :'c3'::uuid);
select public.create_student(:'campus_id'::uuid, 'PTM Kid Four', '2015-04-01'::date, 'female') as c4 \gset
select public.enrol_student(:'sec'::uuid, :'c4'::uuid);
select public.fn_find_or_create_guardian(p_name_en => 'Parent One', p_phone_e164 => '+923009990001') as g1 \gset
select public.link_guardian(:'c1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian(:'c2'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.link_guardian(:'c3'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Parent Two', p_phone_e164 => '+923009990002') as g2 \gset
select public.link_guardian(:'c4'::uuid, :'g2'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as p1_uid \gset
select gen_random_uuid() as p2_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values
  (:'p1_uid', '923009990001', now(), 'x', 'authenticated', 'authenticated'), (:'p2_uid', '923009990002', now(), 'x', 'authenticated', 'authenticated');
update public.guardian set auth_user_id = :'p1_uid' where id = :'g1';
update public.guardian set auth_user_id = :'p2_uid' where id = :'g2';
insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from) values (:'tenant_id', :'campus_id', :'session_id', :'sec', :'ct_uid', current_date - 90);

-- ── the Principal opens an event with a 24-hour cutoff and 10-minute slots ─
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_ptm_event(:'campus_id'::uuid, 'Term 1 PTM', (app.fn_karachi_today() + 5), '10:00'::time) as ev \gset
select is((select booking_cutoff_at = starts_at - interval '24 hours' from public.ptm_event where id = :'ev'::uuid), true, 'the booking cutoff is 24 hours before the event');
select is(public.generate_ptm_slots(:'ev'::uuid, array[:'ct_uid', :'t3_uid']::uuid[], '10:00'::time, '10:50'::time), 10, 'five 10-minute slots are generated for each of two teachers');
select is(public.generate_ptm_slots(:'ev'::uuid, array[:'ct_uid']::uuid[], '10:00'::time, '10:50'::time), 0, 'regenerating adds nothing (idempotent)');
select throws_ok(format($$ select public.book_ptm_slot(%L, %L) $$, (select id from public.ptm_slot where teacher_id = :'ct_uid' limit 1), :'c1'), '42501', null, 'staff cannot book on a parent''s behalf');
select set_config('request.jwt.claims', json_build_object('sub', :'ct_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_ptm_event(%L, 'Rogue', current_date + 3, '09:00') $$, :'campus_id'), 'FORBIDDEN', 'a teacher cannot create a PTM event');
reset role;
select id as s1 from public.ptm_slot where event_id = :'ev'::uuid and teacher_id = :'ct_uid' order by starts_at limit 1 \gset
select id as s2 from public.ptm_slot where event_id = :'ev'::uuid and teacher_id = :'ct_uid' order by starts_at offset 1 limit 1 \gset
select id as s3 from public.ptm_slot where event_id = :'ev'::uuid and teacher_id = :'ct_uid' order by starts_at offset 2 limit 1 \gset
select id as s4 from public.ptm_slot where event_id = :'ev'::uuid and teacher_id = :'ct_uid' order by starts_at offset 3 limit 1 \gset
select id as s_other from public.ptm_slot where event_id = :'ev'::uuid and teacher_id = :'t3_uid' limit 1 \gset

-- ── Parent One has three children ────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p1_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is(jsonb_array_length(public.ptm_slot_list(:'ev'::uuid, :'c1'::uuid)), 5, 'a child''s slot list holds only the teachers of their section (5 slots, not 10)');
select is((public.book_ptm_slot(:'s1'::uuid, :'c1'::uuid) ->> 'ok')::boolean, true, 'a guardian books the 10:00 slot for their child');
reset role;
select is((select count(*) from public.message where idempotency_key = 'ptm_confirm:' || (select id from public.ptm_booking where slot_id = :'s1'::uuid) and status = 'queued'), 1::bigint, 'the booking enqueues a confirmation message (FR-M01 outbox)');
select ok((select body like '%Miss Class Teacher%' and body like '%PTM Kid One%' from public.message where idempotency_key = 'ptm_confirm:' || (select id from public.ptm_booking where slot_id = :'s1'::uuid)), 'naming the teacher and the child');

-- ── AC1: the same slot, a second guardian ────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.book_ptm_slot(:'s1'::uuid, :'c4'::uuid) as lost \gset
select is((:'lost'::jsonb ->> 'ok')::boolean, false, 'AC1: the second booking of the same slot does not succeed');
select is(:'lost'::jsonb ->> 'message', 'slot just taken', 'AC1: it answers ''slot just taken''');
select is(jsonb_array_length(:'lost'::jsonb -> 'slots'), 5, 'AC1: with a refreshed slot list in the same response');
select is((select (e ->> 'available')::boolean from jsonb_array_elements(:'lost'::jsonb -> 'slots') e where e ->> 'slot_id' = :'s1'), false, 'in which the lost slot is shown as taken');
select is((select count(*) from jsonb_array_elements(:'lost'::jsonb -> 'slots') e where (e ->> 'available')::boolean), 4::bigint, 'and the other four are open');
reset role;
select throws_ok(format($$ insert into public.ptm_booking (tenant_id, campus_id, event_id, slot_id, teacher_id, student_id, guardian_id) values (%L, %L, %L, %L, %L, %L, %L) $$,
                        :'tenant_id', :'campus_id', :'ev', :'s1', :'ct_uid', :'c4', :'g2'), '23505', null, 'AC1: even a direct insert cannot double-book the slot (unique index on slot_id)');

-- ── AC4: one slot per child-teacher pair ─────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p1_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is(public.book_ptm_slot(:'s2'::uuid, :'c1'::uuid) ->> 'code', 'pair_already_booked', 'AC4: a second slot with the same teacher for the same child is refused');
select is((public.book_ptm_slot(:'s2'::uuid, :'c2'::uuid) ->> 'ok')::boolean, true, 'AC4: but the second child can book the next slot with that teacher');
select is((public.book_ptm_slot(:'s3'::uuid, :'c3'::uuid) ->> 'ok')::boolean, true, 'AC4: and so can the third child');
select throws_ok(format($$ select public.book_ptm_slot(%L, %L) $$, :'s4', :'c4'), '42501', null, 'a guardian cannot book for another family''s child');
select throws_ok(format($$ select public.book_ptm_slot(%L, %L) $$, :'s_other', :'c1'), 'TEACHER_NOT_FOR_STUDENT', 'nor with a teacher who does not teach the child''s section');

-- ── AC3: cancellation frees the slot at once and offers it on ────────────
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.join_ptm_waitlist(:'s2'::uuid, :'c4'::uuid);
reset role;
select id as b2 from public.ptm_booking where slot_id = :'s2'::uuid and status = 'confirmed' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select throws_ok(format($$ select public.cancel_ptm_booking(%L) $$, :'b2'), '42501', null, 'a guardian cannot cancel another family''s booking');
select set_config('request.jwt.claims', json_build_object('sub', :'p1_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.cancel_ptm_booking(:'b2'::uuid);
select is((select (e ->> 'available')::boolean from jsonb_array_elements(public.ptm_slot_list(:'ev'::uuid, :'c2'::uuid)) e where e ->> 'slot_id' = :'s2'), true, 'AC3: the cancelled slot is bookable again immediately');
reset role;
select is((select count(*) from public.message where idempotency_key like 'ptm_offer:%' and recipient_id = :'g2'::uuid and body like '%now available%'), 1::bigint, 'AC3: and is offered to the next requester on the waiting list');
select ok((select notified_at is not null from public.ptm_waitlist where slot_id = :'s2'::uuid), 'whose waiting-list entry is marked notified');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((public.book_ptm_slot(:'s2'::uuid, :'c4'::uuid) ->> 'ok')::boolean, true, 'AC3: the next requester takes it');

-- ── AC2: cutoff ──────────────────────────────────────────────────────────
reset role;
update public.ptm_event set booking_cutoff_at = clock_timestamp() - interval '1 minute' where id = :'ev'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select public.book_ptm_slot(:'s4'::uuid, :'c4'::uuid) as late \gset
select is(:'late'::jsonb ->> 'code', 'cutoff_passed', 'AC2: one minute past the cutoff the booking is refused');
select ok((:'late'::jsonb ->> 'message') like 'Booking closed at %', 'AC2: and the cutoff time is shown');
reset role;
update public.ptm_event set booking_cutoff_at = clock_timestamp() + interval '1 minute' where id = :'ev'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select set_config('request.jwt.claims', json_build_object('sub', :'p1_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((public.book_ptm_slot(:'s4'::uuid, :'c2'::uuid) ->> 'ok')::boolean, true, 'one minute before the cutoff booking still works');

-- ── visibility ───────────────────────────────────────────────────────────
select is((select count(*) from public.ptm_booking), 4::bigint, 'a guardian sees only their own children''s bookings (3 children: s1, cancelled s2, s3, s4)');
select set_config('request.jwt.claims', json_build_object('sub', :'p2_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.ptm_booking), 1::bigint, 'the other guardian sees only their one booking');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.ptm_booking where status = 'confirmed'), 4::bigint, 'the Principal sees every confirmed booking of the campus');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.ptm_event) + (select count(*) from public.ptm_slot) + (select count(*) from public.ptm_booking), 0::bigint, 'another school sees no PTM data');

select * from finish();
rollback;
