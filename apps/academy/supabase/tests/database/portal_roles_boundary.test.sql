-- pgTAP tests: parents and students read their own family's data and nothing else.
--
-- Parent and student tokens carry campus_ids, and most policies say "owner OR campus_id in token",
-- so every parent and student could read what campus staff read (staff CNICs, bank details, every
-- family's fees, the messaging queue ...) and, on a few tables, write it. The portal roles are now
-- refused on every table that is not on app.fn_portal_tables(), and cannot write the ones that are.
begin;
select plan(40);

-- ── the boundary is complete: nothing is left unclassified ────────────────────────────────
select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relrowsecurity and not c.relispartition
      and c.relname <> all (app.fn_portal_tables())
      and not exists (select 1 from pg_policy p where p.polrelid = c.oid and p.polname = 'portal_roles_blocked' and not p.polpermissive)),
  null,
  'every table that is not on the portal list refuses the parent and student roles'
);
select is(
  (select array_agg(c.relname::text order by c.relname)
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind in ('r', 'p') and c.relrowsecurity and not c.relispartition
      and c.relname = any (app.fn_portal_tables())
      and (select count(*) from pg_policy p where p.polrelid = c.oid and not p.polpermissive
             and p.polname in ('portal_roles_no_insert', 'portal_roles_no_update', 'portal_roles_no_delete')) <> 3),
  null,
  'every table on the portal list refuses direct writes from the parent and student roles'
);
select is(
  (select array_agg(t order by t) from unnest(app.fn_portal_tables()) t where to_regclass('public.' || t) is null),
  null,
  'every name on the portal list is a real table'
);

-- ── fixtures ─────────────────────────────────────────────────────────────────────────────
select public.provision_tenant('test-portal-boundary', 'Portal Boundary Co', 'owner@portalboundary.test');
select id as tenant_id from public.tenant where slug = 'test-portal-boundary' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as stu_uid \gset
select gen_random_uuid() as stu_b_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@portalboundary.test', 'authenticated', 'authenticated', 'x'),
  (:'stu_uid', 's@portalboundary.test', 'authenticated', 'authenticated', 'x'),
  (:'stu_b_uid', 'sb@portalboundary.test', 'authenticated', 'authenticated', 'x');
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role)
values (:'parent_uid', '923005550001', now(), 'x', 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values (:'owner_uid', :'tenant_id', 'owner', 'Boundary Owner');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'owner_uid', :'tenant_id', :'campus_id');

-- rows an UPDATE or DELETE actually touched under the caller's policies and privileges
create function pg_temp.affected(p_sql text) returns int language plpgsql as $$
declare n int;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
exception when insufficient_privilege then
  return 0;  -- refused outright rather than filtered: still nothing changed
end;
$$;
grant execute on function pg_temp.affected(text) to public;

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Boundary Kid A', '2015-01-01'::date, 'male') as student_a \gset
select public.create_student(:'campus_id'::uuid, 'Boundary Kid B', '2015-01-02'::date, 'female') as student_b \gset
select public.enrol_student(:'section_id'::uuid, :'student_a'::uuid) as enrol_a \gset
select public.enrol_student(:'section_id'::uuid, :'student_b'::uuid) as enrol_b \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select public.fn_find_or_create_guardian(p_name_en => 'Boundary Father A', p_phone_e164 => '+923005550001') as guardian_a \gset
select public.link_guardian(:'student_a'::uuid, :'guardian_a'::uuid, 'father'::public.guardian_relationship, true, true);
select public.fn_find_or_create_guardian(p_name_en => 'Boundary Father B', p_phone_e164 => '+923005550002') as guardian_b \gset
select public.link_guardian(:'student_b'::uuid, :'guardian_b'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;

update public.guardian set auth_user_id = :'parent_uid' where id = :'guardian_a';
insert into public.student_portal_account (tenant_id, campus_id, student_id, user_id, status)
values (:'tenant_id', :'campus_id', :'student_a', :'stu_uid', 'active'), (:'tenant_id', :'campus_id', :'student_b', :'stu_b_uid', 'active');
insert into public.staff (tenant_id, campus_id, employee_code, full_name, gender, id_document_type, cnic, doj, employment_status)
values (:'tenant_id', :'campus_id', 'EMP-PB1', 'Boundary Teacher', 'male', 'cnic', '35201-5555555-5', '2026-01-01', 'active')
returning id as staff_id \gset
insert into public.employee_bank_detail (tenant_id, campus_id, staff_id, bank_name, account_title, account_number)
values (:'tenant_id', :'campus_id', :'staff_id', 'HBL', 'Boundary Teacher', '0123456789');
insert into public.admission_enquiry (tenant_id, campus_id, session_id, child_name, dob, class_applied_id, parent_name, phone_e164, source)
values (:'tenant_id', :'campus_id', :'session_id', 'Enquiry Kid', '2020-01-01', :'class1_id', 'Enquiry Parent', '+923009998888', 'walk_in');
insert into public.message (tenant_id, campus_id, body, recipient_phone, channel, status)
values (:'tenant_id', :'campus_id', 'A queued message', '03001110001', 'sms', 'queued');
insert into public.wa_inbound_message (tenant_id, msisdn, body) values (:'tenant_id', '923001110001', 'Hello from another parent');
insert into public.campus_portal_policy (tenant_id, campus_id) values (:'tenant_id', :'campus_id');
set local session_replication_role = replica;
insert into public.concession_award (tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to)
values (:'tenant_id', :'campus_id', :'enrol_b', gen_random_uuid(), 'percentage', 50, current_date, current_date + 30);
insert into public.student_remark (id, tenant_id, campus_id, student_id, author_id, status, current_version_id) values
  ('00000000-0000-0000-0000-0000000000a1', :'tenant_id', :'campus_id', :'student_a', :'owner_uid', 'approved', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-0000000000a2', :'tenant_id', :'campus_id', :'student_b', :'owner_uid', 'approved', '00000000-0000-0000-0000-0000000000b2');
insert into public.student_remark_version (id, tenant_id, remark_id, body, status, created_by) values
  ('00000000-0000-0000-0000-0000000000b1', :'tenant_id', '00000000-0000-0000-0000-0000000000a1', 'A did well', 'approved', :'owner_uid'),
  ('00000000-0000-0000-0000-0000000000b2', :'tenant_id', '00000000-0000-0000-0000-0000000000a2', 'B was late', 'approved', :'owner_uid');
set local session_replication_role = origin;

-- ── a parent of student A ─────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent',
  'campus_ids', json_build_array(:'campus_id'), 'cv', 1)::text, true);

select is((select count(*)::int from public.student), 1, 'a parent still sees their own child');
select is((select count(*)::int from public.enrolment), 1, 'and the child''s enrolment');
select is((select count(*)::int from public.fee_challan), 1, 'and the child''s challan');
select is((select count(*)::int from public.v_portal_dues), 1, 'and the dues view');
select is((select count(*)::int from public.campus_portal_policy), 1, 'and the campus portal policy');
select is((select count(*)::int from public.v_guardian_student_remarks), 1, 'and only their own child''s remark');
select is((select count(*)::int from public.student_remark), 1, 'even straight from the remarks table');
select is((select count(*)::int from public.student_remark_version), 1, 'and its versions');

select is((select count(*)::int from public.staff), 0, 'a parent cannot read the staff register, CNIC numbers included');
select is((select count(*)::int from public.employee_bank_detail), 0, 'nor staff bank details');
select is((select count(*)::int from public.fee_ledger), 0, 'nor any family''s fee ledger');
select is((select count(*)::int from public.fee_plan), 0, 'nor fee plans');
select is((select count(*)::int from public.concession_award), 0, 'nor concession awards');
select is((select count(*)::int from public.admission_enquiry), 0, 'nor other families'' admission enquiries');
select is((select count(*)::int from public.message), 0, 'nor the messaging queue');
select is((select count(*)::int from public.wa_inbound_message), 0, 'nor inbound WhatsApp messages');
select is((select count(*)::int from public.student_portal_account), 0, 'nor the students'' portal accounts');
select is((select count(*)::int from public.user_campus), 0, 'nor who works at which campus');

select throws_ok(
  format($$ insert into public.message (tenant_id, campus_id, body) values (%L, %L, 'spam') $$, :'tenant_id', :'campus_id'),
  '42501', null, 'a parent cannot put a message in the outbound queue'
);
select is(pg_temp.affected($$ update public.student_remark set status = 'rejected' $$), 0, 'cannot change a remark');
select is(pg_temp.affected($$ delete from public.student_remark $$), 0, 'cannot delete a remark');
select is(pg_temp.affected($$ update public.campus_portal_policy set show_rank = true $$), 0, 'cannot change the campus portal policy');
select is(pg_temp.affected($$ update public.student set name_en = 'Changed' $$), 0, 'cannot edit their child''s student record directly');
reset role;

-- ── a student ─────────────────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'stu_uid', 'tenant_id', :'tenant_id', 'app_role', 'student',
  'campus_ids', json_build_array(:'campus_id'), 'student_id', :'student_a', 'cv', 1)::text, true);
select is((select count(*)::int from public.student), 1, 'a student still sees their own record');
select is((select count(*)::int from public.enrolment), 1, 'and their enrolment');
select is((select count(*)::int from public.student_portal_account), 1, 'and their own portal account only');
select is((select count(*)::int from public.app_user), 0, 'a student cannot read the staff user list');
select is((select count(*)::int from public.staff), 0, 'nor the staff register');
select is((select count(*)::int from public.fee_ledger), 0, 'nor the fee ledger');
select is((select count(*)::int from public.message), 0, 'nor the messaging queue');
select throws_ok(
  format($$ insert into public.message (tenant_id, campus_id, body) values (%L, %L, 'spam') $$, :'tenant_id', :'campus_id'),
  '42501', null, 'and cannot queue a message'
);
select is(pg_temp.affected($$ update public.student_portal_account set status = 'disabled' $$), 0, 'or change a portal account');
reset role;

-- ── staff are unaffected ──────────────────────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.fee_ledger) > 0, 'an accountant still reads the fee ledger');
select is((select count(*)::int from public.staff), 1, 'and the staff register');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select ok((select count(*) from public.app_user) > 0, 'a teacher still reads the user list');
select is((select count(*)::int from public.student), 2, 'and the campus''s students');
select set_config('request.jwt.claims', json_build_object('role', 'authenticated', 'sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select lives_ok(
  format($$ insert into public.message (tenant_id, campus_id, body, recipient_phone, channel) values (%L, %L, 'a staff message', '03001110009', 'sms') $$, :'tenant_id', :'campus_id'),
  'and staff can still write where they could before'
);
reset role;

select * from finish();
rollback;
