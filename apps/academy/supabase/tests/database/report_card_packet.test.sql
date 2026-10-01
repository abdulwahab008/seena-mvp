-- pgTAP tests for FR-J11: next-term fee slip with the report card.
--
--   AC1  a First Term report card and a generated challan for the next cycle:
--        the packet carries the card and the 3-copy challan with barcode and
--        due date.
--   AC2  no challan generated: the card alone, and the batch summary lists
--        the affected candidate count.
--   AC3  a 25% sibling-discount student: the challan payable matches the fee
--        module amount to the rupee, with no recalculation here.
--   AC4  a withheld result: neither card nor packet, while the challan stays
--        available from the fee module.
begin;
select plan(31);

select public.provision_tenant('test-packet-co', 'Packet Co', 'owner@packetco.test');
select id as tenant_id from public.tenant where slug = 'test-packet-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
select public.provision_tenant('test-packet-rival', 'Packet Rival', 'owner@packetrival.test');
select id as rival_id from public.tenant where slug = 'test-packet-rival' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as acc_uid \gset
select gen_random_uuid() as teacher_uid \gset
select gen_random_uuid() as parent_a_uid \gset
select gen_random_uuid() as parent_c_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@packetco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'acc_uid', 'a@packetco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'teacher_uid', 't@packetco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent_a_uid', 'pa@packetco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent_c_uid', 'pc@packetco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@packetrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'acc_uid', :'tenant_id', 'accountant', 'Accounts Clerk'),
  (:'teacher_uid', :'tenant_id', 'subject_teacher', 'A Teacher'), (:'rival_uid', :'rival_id', 'owner', 'Rival');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'acc_uid', :'tenant_id', :'campus_id'), (:'teacher_uid', :'tenant_id', :'campus_id');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_uid')::text, true);
select public.create_section(:'campus_id', :'session_id', :'class5', 'A', 40) as sec \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term \gset
select public.create_student(:'campus_id', 'Ayesha Noor', '2013-01-01'::date, 'female') as st_a \gset
select public.create_student(:'campus_id', 'Bilal Ahmed', '2013-02-01'::date, 'male') as st_b \gset
select public.create_student(:'campus_id', 'Chandni Rao', '2013-03-01'::date, 'female') as st_c \gset
select public.create_student(:'campus_id', 'Danish Ali', '2013-04-01'::date, 'male') as st_d \gset
select public.enrol_student(:'sec', :'st_a') as e_a \gset
select public.enrol_student(:'sec', :'st_b') as e_b \gset
select public.enrol_student(:'sec', :'st_c') as e_c \gset
select public.enrol_student(:'sec', :'st_d') as e_d \gset
select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550051') as g_a \gset
select public.link_guardian(:'st_a'::uuid, :'g_a'::uuid, 'mother'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Chandni Mother', p_phone_e164 => '+923005550052') as g_c \gset
select public.link_guardian(:'st_c'::uuid, :'g_c'::uuid, 'mother'::public.guardian_relationship, true, true);

reset role;
update public.guardian set auth_user_id = :'parent_a_uid'::uuid where id = :'g_a'::uuid;
update public.guardian set auth_user_id = :'parent_c_uid'::uuid where id = :'g_c'::uuid;

-- Four issued First Term report cards (FR-J09's output, written as it would
-- have been), all issued this month.
insert into public.report_card (tenant_id, campus_id, exam_term_id, section_id, enrolment_id, revision_no, storage_path, checksum, status, payload_snapshot, rendered_at)
select :'tenant_id', :'campus_id', :'term', :'sec', e, 1, format('%s/%s/%s/card-%s.pdf', :'tenant_id', :'campus_id', :'term', e), repeat('c', 64), 'issued', '{"term":{"name":"First Term"}}'::jsonb, now()
  from (values (:'e_a'::uuid), (:'e_b'::uuid), (:'e_c'::uuid), (:'e_d'::uuid)) v(e);

-- The fee module's challans for NEXT month. Ayesha is on a 25% sibling
-- discount: 10,000.00 gross, 2,500.00 off, 7,500.00 payable. Chandni has one
-- too (her result is withheld). Danish only has this month's challan.
insert into public.fee_challan (tenant_id, campus_id, enrolment_id, session_id, student_id, billing_period, challan_no, issue_date, due_date,
                                gross_paisa, concession_paisa, arrears_paisa, net_paisa, status)
values
  (:'tenant_id', :'campus_id', :'e_a', :'session_id', :'st_a', (date_trunc('month', now()) + interval '1 month')::date, 'CH-PKT-0001', current_date, (current_date + 25),
   1000000, 250000, 0, 750000, 'unpaid'),
  (:'tenant_id', :'campus_id', :'e_c', :'session_id', :'st_c', (date_trunc('month', now()) + interval '1 month')::date, 'CH-PKT-0003', current_date, (current_date + 25),
   1000000, 0, 0, 1000000, 'unpaid'),
  (:'tenant_id', :'campus_id', :'e_d', :'session_id', :'st_d', date_trunc('month', now())::date, 'CH-PKT-0004', current_date, (current_date + 5),
   1000000, 0, 0, 1000000, 'unpaid');
insert into public.result_withhold (tenant_id, campus_id, exam_term_id, enrolment_id, reason, cutoff_date)
values (:'tenant_id', :'campus_id', :'term', :'e_c', 'discipline', current_date);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'acc_uid')::text, true);

-- ── AC2: the batch summary ────────────────────────────────────────────────
select public.fn_report_card_packet_plan(:'term'::uuid, :'sec'::uuid) as plan \gset
select is((:'plan'::jsonb ->> 'with_challan_count')::int, 1, 'the plan counts one candidate with a next-cycle challan');
select is((:'plan'::jsonb ->> 'card_only_count')::int, 2, 'AC2: two candidates have no challan for the cycle: Bilal and Danish (whose only challan is this month''s)');
select is((:'plan'::jsonb ->> 'withheld_count')::int, 1, 'and one result is withheld');
select is((:'plan'::jsonb -> 'card_only')::text, '["Bilal Ahmed", "Danish Ali"]', 'AC2: the affected candidates are listed by name');

-- ── AC1 + AC3 ─────────────────────────────────────────────────────────────
select public.begin_report_card_packet(:'e_a'::uuid, :'term'::uuid) as pkt_a \gset
select is((:'pkt_a'::jsonb ->> 'with_challan')::boolean, true, 'AC1: Ayesha''s packet carries the next cycle''s challan');
select is(:'pkt_a'::jsonb -> 'challan' -> 'copies', '["bank", "school", "student"]'::jsonb, 'AC1: the challan is the 3-copy one: bank, school, student');
select is(:'pkt_a'::jsonb -> 'challan' ->> 'barcode_value', 'CH-PKT-0001', 'AC1: it carries the barcode value');
select is(:'pkt_a'::jsonb -> 'challan' ->> 'due_date', (current_date + 25)::text, 'AC1: and the due date');
select is((:'pkt_a'::jsonb -> 'challan' ->> 'net_paisa')::bigint, 750000::bigint, 'AC3: the challan payable is 7,500.00, the sibling-discounted amount');
select is((select payable_paisa from public.report_card_packet where enrolment_id = :'e_a'), (select net_paisa from public.fee_challan where challan_no = 'CH-PKT-0001'),
          'AC3: to the rupee the fee module''s fee_challan.net_paisa');
select is((:'pkt_a'::jsonb -> 'challan' ->> 'concession_paisa')::bigint, 250000::bigint, 'AC3: the 25% concession is the fee module''s, not recomputed');
select is(:'pkt_a'::jsonb ->> 'storage_path', format('%s/%s/%s/packet-%s.pdf', :'tenant_id', :'campus_id', :'term', :'e_a'), 'the packet path is {tenant}/{campus}/{term}/packet-{enrolment}.pdf');
select is(:'pkt_a'::jsonb -> 'snapshot' -> 'term' ->> 'name', 'First Term', 'the packet starts from the issued report card''s snapshot');
select is((select assembled_at from public.report_card_packet where enrolment_id = :'e_a'), null, 'a reserved packet is not assembled until its PDF is sealed');
select throws_ok(format($$select public.attach_report_card_packet(%L, 'nothex')$$, :'pkt_a'::jsonb ->> 'packet_id'), 'CHECKSUM_INVALID', 'sealing needs a real sha-256');
select public.attach_report_card_packet((:'pkt_a'::jsonb ->> 'packet_id')::uuid, repeat('a', 64)) as _att \gset
select isnt((select assembled_at from public.report_card_packet where enrolment_id = :'e_a'), null, 'sealing stamps assembled_at');

-- Read live, never carried: the fee module changes the amount, re-assembly follows.
reset role;
update public.fee_challan set net_paisa = 700000, concession_paisa = 300000 where challan_no = 'CH-PKT-0001';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'acc_uid')::text, true);
select public.begin_report_card_packet(:'e_a'::uuid, :'term'::uuid) as pkt_a2 \gset
select is((select payable_paisa from public.report_card_packet where enrolment_id = :'e_a'), 700000::bigint, 'AC3: re-assembling reads the fee module again (7,000.00) rather than carrying the old figure');
select is((select count(*)::int from public.report_card_packet where enrolment_id = :'e_a'), 1, 'uq_packet: re-assembly updates the one packet per report card');
select is((select assembled_at from public.report_card_packet where enrolment_id = :'e_a'), null, 'and it is unsealed again until the new PDF is attached');
select public.attach_report_card_packet((:'pkt_a2'::jsonb ->> 'packet_id')::uuid, repeat('b', 64)) as _att2 \gset

-- ── AC2: the card alone ───────────────────────────────────────────────────
select public.begin_report_card_packet(:'e_b'::uuid, :'term'::uuid) as pkt_b \gset
select is((:'pkt_b'::jsonb ->> 'with_challan')::boolean, false, 'AC2: with no challan the packet is the report card alone');
select is((select challan_id from public.report_card_packet where enrolment_id = :'e_b'), null, 'and references no challan');
select is((select payable_paisa from public.report_card_packet where enrolment_id = :'e_b'), null, 'and carries no amount');
select is((:'pkt_b'::jsonb -> 'challan')::text, 'null', 'and no challan section is handed to the renderer');

-- An explicit cycle picks the challan of that month, even this month's.
select is(((public.begin_report_card_packet(:'e_d'::uuid, :'term'::uuid, date_trunc('month', now())::date)) ->> 'with_challan')::boolean, true,
          'naming the billing period picks that month''s challan');

-- ── AC4: withheld ─────────────────────────────────────────────────────────
select throws_ok(format($$select public.begin_report_card_packet(%L, %L)$$, :'e_c', :'term'), '23514', null, 'AC4: a withheld result is refused');
select is((select count(*)::int from public.report_card_packet where enrolment_id = :'e_c'), 0, 'AC4: no packet exists for the withheld candidate');
select isnt(public.portal_challan_payload((select id from public.fee_challan where challan_no = 'CH-PKT-0003')), null, 'AC4: while the challan stays available from the fee module');

-- ── who may, and who sees ─────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_uid')::text, true);
select throws_ok(format($$select public.begin_report_card_packet(%L, %L)$$, :'e_a', :'term'), '42501', null, 'a subject teacher cannot assemble packets');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent_a_uid')::text, true);
select is((select count(*)::int from public.report_card_packet), 1, 'a parent sees only their own child''s sealed packet');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'parent_c_uid')::text, true);
select is((select count(*)::int from public.report_card_packet), 0, 'a parent whose child''s result is withheld sees none');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select is((select count(*)::int from public.report_card_packet), 0, 'another school sees none');

select * from finish();
rollback;
