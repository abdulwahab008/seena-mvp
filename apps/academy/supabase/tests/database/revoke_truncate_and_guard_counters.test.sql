-- pgTAP tests for 20260731999100_revoke_truncate_and_guard_counters.sql.
--
-- The defect was found by running `truncate public.student cascade` as a
-- signed-in subject_teacher and watching it empty roughly forty-four
-- tables, so that is the first thing asserted here, in those words. Every
-- other TRUNCATE assertion names its table directly as `authenticated`
-- too: TRUNCATE consults no policy and fires no row trigger, so the only
-- thing that can refuse it is a table privilege or a statement trigger,
-- and the only way to test either is to run the statement.
--
-- Two roles matter and both are exercised. `authenticated` is every
-- application role — super_admin and subject_teacher reach the database as
-- the same Postgres role — and is now refused by privilege, before any
-- trigger is reached. `service_role` holds BYPASSRLS and every grant by
-- design, so for it the privilege is never the answer and the statement
-- triggers are; it is asserted separately, against both the counters and
-- the irreplaceable registers.
--
-- The `zz_truncate_default_priv_probe` table exists to prove the half of
-- the fix that a one-time revoke cannot deliver: it is created after the
-- migration ran, so what it is born holding is decided by
-- pg_default_acl, not by the REVOKE. Without the ALTER DEFAULT PRIVILEGES
-- half, this table — and every table a future migration adds — would carry
-- TRUNCATE for authenticated again.
begin;
select plan(49);

select public.provision_tenant('test-trunc-revoke-co', 'Truncate Revoke Co', 'owner@truncrevoke.test');
select id as tenant_id from public.tenant where slug = 'test-trunc-revoke-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

-- A second campus, so the "a series cannot be seeded part-way up" attempts
-- below have somewhere to aim that has no counter row yet. Creating it
-- also runs app.tg_seed_gr_sequence() through the new INSERT guard.
insert into public.campus (tenant_id, code, name) values (:'tenant_id'::uuid, 'NORTH', 'North Campus')
returning id as campus_b \gset

select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_b'::uuid),
  1::bigint,
  'app.tg_seed_gr_sequence() still seeds a new campus''s GR register at one'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The allocators still allocate (run first, so every counter below holds
-- a real value that the tamper attempts have something to fail against)
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_id', :'campus_b'))::text,
  true
);

select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);

select public.create_student(:'campus_id'::uuid, 'Register Child', '2015-01-01'::date, 'male') as student_id \gset
select is(
  (select gr_number from public.student where id = :'student_id'::uuid),
  'MAIN-000001',
  'app.fn_allocate_gr_number() still allocates from the campus GR register'
);

select public.enrol_student(:'section_id'::uuid, :'student_id'::uuid) as enrol_id \gset

select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'First Applicant',
  p_dob => '2020-01-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent One',
  p_phone => '03001111111', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry1 \gset
select public.create_enquiry(
  p_campus_id => :'campus_id', p_session_id => :'session_id', p_child_name => 'Second Applicant',
  p_dob => '2020-02-01'::date, p_class_applied_id => :'class1_id', p_parent_name => 'Parent Two',
  p_phone => '03002222222', p_whatsapp_opt_in => false, p_source => 'walk_in'
) as enquiry2 \gset

select is(
  (select array_agg(right(enquiry_no, 5) order by enquiry_no) from public.admission_enquiry
    where id in (:'enquiry1'::uuid, :'enquiry2'::uuid)),
  array['00001', '00002'],
  'public.fn_next_enquiry_no() still allocates, and still allocates consecutively'
);

select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select id as challan_id, challan_no from public.fee_challan where enrolment_id = :'enrol_id' \gset
select is(
  left(:'challan_no', 11),
  '00000000001',
  'public.next_challan_no() still allocates, and a fresh counter still starts at one'
);

select public.collect_cash_payment(:'challan_id'::uuid, 500000::bigint, 'trunc-revoke-idem-1') as collect_result \gset
select is(
  (:'collect_result'::jsonb ->> 'receipt_no'),
  'RCP-00000001',
  'app.fn_next_receipt_no() still allocates through collect_cash_payment(), which is its only caller'
);

-- The documented "school migrating from a paper register" path: an
-- arbitrary rewrite of prefix, start and width, which the guard has to
-- keep allowing because refusing it would break the FR, and which is safe
-- only because set_gr_sequence() checks the caller's role and campus.
select public.set_gr_sequence(:'campus_id'::uuid, 'OLD', 5000::bigint, 4::smallint);
select public.create_student(:'campus_id'::uuid, 'Carried Forward Child', '2015-02-01'::date, 'female') as student2_id \gset
select is(
  (select gr_number from public.student where id = :'student2_id'::uuid),
  'OLD-5000',
  'public.set_gr_sequence() still carries a paper register forward, prefix, width and start together'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The vulnerability, attacked exactly as it was found
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select throws_like(
  $$ truncate public.student cascade $$,
  '%permission denied%',
  'the statement that emptied forty-four tables — as a subject_teacher, the lowest-privilege signed-in role there is'
);
select throws_like(
  $$ truncate public.fee_ledger cascade $$,
  '%permission denied%',
  'and the ledger of what every family owes'
);
select throws_like(
  $$ truncate public.fee_payment cascade $$,
  '%permission denied%',
  'and the record of money actually received'
);
select throws_like(
  $$ truncate public.mark_entry $$,
  '%permission denied%',
  'and the marks as the teacher entered them'
);
select throws_like(
  $$ truncate public.attendance_day $$,
  '%permission denied%',
  'and the attendance register'
);
select throws_like(
  $$ truncate public.enrolment cascade $$,
  '%permission denied%',
  'and the enrolment register'
);
select throws_like(
  $$ truncate public.gr_sequence $$,
  '%permission denied%',
  'and the GR counter, whose series is cited in board correspondence'
);
select throws_like(
  $$ truncate public.certificate_serial_counter $$,
  '%permission denied%',
  'and the certificate serial counter, the one counter FR-T02 left without a TRUNCATE guard'
);
select throws_like(
  $$ truncate public.challan_counter $$,
  '%permission denied%',
  'and the challan counter'
);
select throws_like(
  $$ truncate public.fee_receipt_counter $$,
  '%permission denied%',
  'and the receipt counter'
);
select throws_like(
  $$ truncate public.enquiry_no_counter $$,
  '%permission denied%',
  'and the enquiry counter'
);
select throws_like(
  $$ truncate public.fee_head $$,
  '%permission denied%',
  'and a table that carries no statement trigger at all — the revoke, not the triggers, is what covers the other 170'
);
select throws_like(
  $$ truncate public.audit_log $$,
  '%permission denied%',
  'and the audit trail, which now refuses on privilege before its own guard is ever reached'
);

-- TRIGGER and REFERENCES went with it: both let a holder attach machinery
-- to a table they should only read.
--
-- Extension-owned relations are excluded, and the exclusion is itself the
-- evidence for what the migration's header says about pg_default_acl. The
-- test harness installs pgTAP into public for the duration of the run, and
-- pgTAP's two views (pg_all_foreign_keys, tap_funky) come out owned by
-- supabase_admin, so they inherit supabase_admin's default ACL — the one
-- entry postgres is not a member of and cannot alter. They are views,
-- hold no data, and vanish with the extension; every relation this
-- application creates is owned by postgres and is covered.
reset role;
create or replace function pg_temp.leaked_grants(p_privilege text)
returns int
language sql
stable
as $$
  select count(*)::int
    from information_schema.role_table_grants g
    join pg_catalog.pg_class c on c.relname = g.table_name
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace and n.nspname = g.table_schema
   where g.table_schema = 'public'
     and g.grantee in ('anon', 'authenticated')
     and g.privilege_type = p_privilege
     and not exists (
       select 1 from pg_catalog.pg_depend d
        where d.classid = 'pg_class'::regclass and d.objid = c.oid and d.deptype = 'e'
     );
$$;

select is(
  pg_temp.leaked_grants('TRUNCATE'),
  0,
  'no table in public grants TRUNCATE to anon or authenticated any more'
);
select is(
  pg_temp.leaked_grants('TRIGGER'),
  0,
  'nor TRIGGER, which would let a client run code inside another tenant''s writes'
);
select is(
  pg_temp.leaked_grants('REFERENCES'),
  0,
  'nor REFERENCES, which would let a client wedge another tenant''s rows against deletion'
);

-- ═══════════════════════════════════════════════════════════════════════
-- A table created AFTER the revoke: the half a one-time REVOKE cannot do
-- ═══════════════════════════════════════════════════════════════════════

create table public.zz_truncate_default_priv_probe (id int primary key);

select is(
  (select count(*)::int from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'zz_truncate_default_priv_probe'
      and grantee in ('anon', 'authenticated')
      and privilege_type in ('TRUNCATE', 'TRIGGER', 'REFERENCES')),
  0,
  'a table created after the migration is born without TRUNCATE, TRIGGER or REFERENCES — pg_default_acl, not the REVOKE, is what did that'
);
select is(
  (select array_agg(distinct privilege_type::text order by privilege_type::text)
     from information_schema.role_table_grants
    where table_schema = 'public' and table_name = 'zz_truncate_default_priv_probe'
      and grantee = 'authenticated'),
  array['DELETE', 'INSERT', 'SELECT', 'UPDATE'],
  'and still born with the four privileges PostgREST actually needs, so the revoke did not over-reach'
);

set local role authenticated;
select throws_like(
  $$ truncate public.zz_truncate_default_priv_probe $$,
  '%permission denied%',
  'so the next migration''s tables are covered without anyone remembering to cover them'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- service_role: the belt-and-braces triggers, which are all it meets
-- ═══════════════════════════════════════════════════════════════════════

set local role service_role;

select throws_ok(
  $$ truncate public.mark_entry $$,
  '42501',
  'table public.mark_entry cannot be truncated',
  'service_role keeps the privilege by design, so the statement trigger is what refuses — by name'
);
select throws_ok(
  $$ truncate public.student cascade $$,
  '42501',
  null,
  'and the original cascade is refused for it too, somewhere in the guarded set it reaches'
);
select throws_ok(
  $$ truncate public.gr_sequence $$,
  '42501',
  'number counters cannot be truncated',
  'the GR counter refuses with the counters'' own message'
);
select throws_ok(
  $$ truncate public.certificate_serial_counter $$,
  '42501',
  'number counters cannot be truncated',
  'and so does certificate_serial_counter, whose missing guard would have reset every campus''s series to zero'
);
select throws_ok(
  $$ truncate public.fee_receipt_counter cascade $$,
  '42501',
  'number counters cannot be truncated',
  'and TRUNCATE ... CASCADE is refused the same way'
);

-- ═══════════════════════════════════════════════════════════════════════
-- service_role cannot rewind any of the four counters
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ update public.gr_sequence set next_value = 1 where campus_id = %L $$, :'campus_id'),
  '42501',
  'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()',
  'rewinding a GR register — `update public.gr_sequence set next_value = 1` returned UPDATE 17 before this migration — is refused'
);
select throws_ok(
  format($$ update public.gr_sequence set next_value = next_value + 1 where campus_id = %L $$, :'campus_id'),
  '42501',
  'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()',
  'and so is an increment of exactly one that does not come from the allocator — the allow-list is a call-stack check, not a magic value'
);
select throws_ok(
  format($$ delete from public.gr_sequence where campus_id = %L $$, :'campus_id'),
  '42501',
  'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()',
  'and deleting the row, which would restart the register at one'
);
select throws_ok(
  format($$ insert into public.gr_sequence (tenant_id, campus_id, prefix, next_value) values (%L, %L, 'X', 9000) $$,
         :'tenant_id', :'campus_b'),
  '42501',
  'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()',
  'and seeding a register part-way up outside the campus trigger'
);

select throws_ok(
  format($$ update public.enquiry_no_counter set next_seq = 1 where campus_id = %L $$, :'campus_id'),
  '42501',
  'enquiry number counters are advanced only by fn_next_enquiry_no()',
  'rewinding enquiry numbers, which would reissue numbers already quoted to families, is refused'
);
select throws_ok(
  format($$ delete from public.enquiry_no_counter where campus_id = %L $$, :'campus_id'),
  '42501',
  'enquiry number counters are advanced only by fn_next_enquiry_no()',
  'and so is deleting an enquiry counter row'
);
select throws_ok(
  format($$ insert into public.enquiry_no_counter (campus_id, session_id, next_seq) values (%L, %L, 500) $$,
         :'campus_b', :'session_id'),
  '42501',
  'enquiry number counters are advanced only by fn_next_enquiry_no()',
  'and seeding an enquiry series part-way up'
);

select throws_ok(
  format($$ update public.challan_counter set last_no = 0 where campus_id = %L $$, :'campus_id'),
  '42501',
  'challan number counters are advanced only by next_challan_no()',
  'rewinding challan numbers, which the bank validates by check digit, is refused'
);
select throws_ok(
  format($$ delete from public.challan_counter where campus_id = %L $$, :'campus_id'),
  '42501',
  'challan number counters are advanced only by next_challan_no()',
  'and so is deleting a challan counter row'
);
select throws_ok(
  format($$ insert into public.challan_counter (tenant_id, campus_id, session_id, last_no) values (%L, %L, %L, 500) $$,
         :'tenant_id', :'campus_b', :'session_id'),
  '42501',
  'challan number counters are advanced only by next_challan_no()',
  'and seeding a challan series part-way up'
);

select throws_ok(
  format($$ update public.fee_receipt_counter set last_no = 0 where campus_id = %L $$, :'campus_id'),
  '42501',
  'receipt number counters are advanced only by app.fn_next_receipt_no()',
  'rewinding receipt numbers, which index the cash book, is refused'
);
select throws_ok(
  format($$ delete from public.fee_receipt_counter where campus_id = %L $$, :'campus_id'),
  '42501',
  'receipt number counters are advanced only by app.fn_next_receipt_no()',
  'and so is deleting a receipt counter row'
);
select throws_ok(
  format($$ insert into public.fee_receipt_counter (tenant_id, campus_id, session_id, last_no) values (%L, %L, %L, 500) $$,
         :'tenant_id', :'campus_b', :'session_id'),
  '42501',
  'receipt number counters are advanced only by app.fn_next_receipt_no()',
  'and seeding a receipt series part-way up'
);
reset role;

-- The DELETE refusal covers the FK cascade too, the same posture FR-T02
-- and 20260731999000 already take: no application role holds a DELETE
-- policy on campus, and orphaning a live number series is worse than
-- refusing the delete.
-- campus_b, whose only guarded child is its GR register, so the refusal
-- that speaks is unambiguously the one this migration added.
select throws_ok(
  format($$ delete from public.campus where id = %L $$, :'campus_b'),
  '42501',
  'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()',
  'a campus can no longer be cascaded away out from under its GR register'
);

-- ═══════════════════════════════════════════════════════════════════════
-- After every attempt above, each counter still reads what its allocator
-- left it
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_id'::uuid),
  5001::bigint,
  'gr_sequence still reads what set_gr_sequence() and one admission left it'
);
select is(
  (select next_seq from public.enquiry_no_counter where campus_id = :'campus_id'::uuid and session_id = :'session_id'::uuid),
  3,
  'enquiry_no_counter still reads three after two enquiries'
);
select is(
  (select last_no from public.challan_counter where campus_id = :'campus_id'::uuid and session_id = :'session_id'::uuid),
  1::bigint,
  'challan_counter still reads one after one challan'
);
select is(
  (select last_no from public.fee_receipt_counter where campus_id = :'campus_id'::uuid and session_id = :'session_id'::uuid),
  1::bigint,
  'fee_receipt_counter still reads one after one collection'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The guarded set is what the migration says it is
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select count(*)::int from pg_trigger t
     join pg_class c on c.oid = t.tgrelid
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and not t.tgisinternal and (t.tgtype & 32) <> 0
      and c.relname in ('fee_ledger', 'fee_payment', 'fee_payment_allocation', 'fee_receipt',
                        'fee_challan', 'fee_challan_line', 'cash_book_day', 'expense_voucher',
                        'mark_entry', 'attendance_audit',
                        'student', 'gr_ledger', 'enrolment', 'attendance_day', 'staff',
                        'gr_sequence', 'enquiry_no_counter', 'challan_counter',
                        'fee_receipt_counter', 'certificate_serial_counter')),
  20,
  'all twenty money, marks, register and counter tables carry their own BEFORE TRUNCATE guard'
);

select * from finish();
rollback;
