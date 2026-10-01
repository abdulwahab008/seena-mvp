-- pgTAP tests for FR-O02: per-copy accession and barcode register.
begin;
select plan(20);

select public.provision_tenant('test-libcopy-co', 'Lib Copy Co', 'owner@libcopy.test');
select id as tenant_id from public.tenant where slug = 'test-libcopy-co' \gset
select id as gulberg_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'JT', 'Johar Town') returning id as johar_id \gset

select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as stud_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'lib_uid', 'l@libcopy.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@libcopy.test', 'authenticated', 'authenticated', 'x'),
  (:'stud_uid', 's@libcopy.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'stud_uid', :'tenant_id', 'student', 'Student');

insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics 9') returning id as title_x \gset
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Chemistry 9') returning id as title_y \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'gulberg_id', :'johar_id'))::text, true);

-- 6 copies of X at Gulberg, 3 at Johar Town
select public.register_library_copy(:'title_x'::uuid, :'gulberg_id'::uuid, 'LIB-2026-' || lpad(n::text, 5, '0'), 'BC-G-' || n, 'A1', 85000, '2026-01-10') from generate_series(1, 6) n;
select public.register_library_copy(:'title_x'::uuid, :'johar_id'::uuid, 'LIB-2026-J' || lpad(n::text, 4, '0'), 'BC-J-' || n) from generate_series(1, 3) n;
select is((select count(*) from public.library_copy where title_id = :'title_x'::uuid), 9::bigint, 'nine copies registered across two campuses');

-- ── AC1: availability is per campus ───────────────────────────────────────
reset role;
update public.library_copy set status = 'issued' where tenant_id = :'tenant_id' and barcode in ('BC-G-1', 'BC-G-2', 'BC-G-3', 'BC-G-4');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'stud_uid', 'tenant_id', :'tenant_id', 'app_role', 'student', 'campus_ids', json_build_array(:'gulberg_id'))::text, true);
select is((select available_copies from public.v_title_availability where title_id = :'title_x'::uuid), 2, 'AC1: a Gulberg student sees 2 available');
select is((select total_copies from public.v_title_availability where title_id = :'title_x'::uuid), 6, 'AC1: out of 6');
select is((select count(*) from public.v_title_availability where title_id = :'title_x'::uuid), 1::bigint, 'AC1: only the Gulberg row, Johar Town stock is excluded');
select is((select count(*) from public.library_copy where campus_id = :'johar_id'::uuid), 0::bigint, 'AC1: Johar Town copies are invisible to a Gulberg student');

-- ── AC2: accession numbers are never reused, even after write-off ─────────
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'gulberg_id', :'johar_id'))::text, true);
select public.register_library_copy(:'title_y'::uuid, :'gulberg_id'::uuid, 'LIB-2026-00431', 'BC-431') as c431 \gset
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'LIB-2026-00431', 'BC-NEW') $$, :'title_y', :'gulberg_id'), 'DUPLICATE_ACCESSION', 'AC2: a duplicate accession number is rejected');
reset role;
update public.library_copy set status = 'written_off' where id = :'c431'::uuid;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'gulberg_id', :'johar_id'))::text, true);
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'LIB-2026-00431', 'BC-NEW2') $$, :'title_y', :'gulberg_id'), 'DUPLICATE_ACCESSION', 'AC2: still rejected after the original is written_off');
select throws_ok(format($$ insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) values (%L, %L, %L, 'LIB-2026-00431', 'BC-X') $$, :'tenant_id', :'gulberg_id', :'title_y'), '42501', null, 'direct inserts are refused for clients');
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'LIB-NEW-1', 'BC-G-2') $$, :'title_y', :'gulberg_id'), 'DUPLICATE_BARCODE', 'a duplicate barcode is rejected');
reset role;
select throws_ok(format($$ delete from public.library_copy where id = %L $$, :'c431'), 'LIBRARY_COPY_NOT_DELETABLE', 'a copy row can never be deleted, so its accession number stays on the register');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'gulberg_id', :'johar_id'))::text, true);

-- ── lost copies are not available (issue refusal itself is asserted with FR-O04) ──
select public.register_library_copy(:'title_y'::uuid, :'gulberg_id'::uuid, 'LIB-2026-00500', 'BC-500') as c500 \gset
select public.set_library_copy_status(:'c500'::uuid, 'lost');
select is((select status::text from public.library_copy where id = :'c500'::uuid), 'lost', 'a copy can be marked lost');
select is((select available_copies from public.v_title_availability where title_id = :'title_y'::uuid and campus_id = :'gulberg_id'::uuid), 0, 'a lost copy is not counted as available');
select throws_ok(format($$ select public.set_library_copy_status(%L, 'issued') $$, :'c500'), '55000', null, 'issued cannot be set by hand');

-- ── AC4: atomic CSV import ────────────────────────────────────────────────
select is(
  (public.import_library_copies(:'gulberg_id'::uuid, (select jsonb_agg(jsonb_build_object('title_id', :'title_y', 'accession_no', 'IMP-' || n, 'barcode', 'IBC-' || n, 'purchase_cost', 12000) order by n) from generate_series(1, 500) n))->>'imported')::int,
  500, 'a clean 500-row import commits every row');
create temp table imp_rows as
  select n, case when n in (100, 250, 400) then 'IBC-' || (n - 50) else 'NB-' || n end as barcode from generate_series(1, 500) n;
grant select on imp_rows to public;
select public.import_library_copies(:'gulberg_id'::uuid, (select jsonb_agg(jsonb_build_object('title_id', :'title_y', 'accession_no', 'ACC2-' || n, 'barcode', barcode) order by n) from imp_rows)) as report \gset
select is(:'report'::jsonb -> 'ok', 'false'::jsonb, 'AC4: an import with duplicate barcodes fails');
select is(:'report'::jsonb -> 'duplicate_barcode_rows', '[100, 250, 400]'::jsonb, 'AC4: and reports the 3 offending row numbers');
select is((select count(*) from public.library_copy where accession_no like 'ACC2-%'), 0::bigint, 'AC4: nothing from the failed import was written (atomic)');
select is((public.import_library_copies(:'gulberg_id'::uuid, '[{"isbn":"","accession_no":"Z1","barcode":"Z1"}]'::jsonb) -> 'errors' -> 0 ->> 'code'), 'TITLE_NOT_FOUND', 'a row whose title cannot be resolved is reported');

-- ── access ────────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'gulberg_id'))::text, true);
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'T-1', 'T-1') $$, :'title_y', :'gulberg_id'), 'FORBIDDEN', 'a teacher cannot register copies');
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'gulberg_id'))::text, true);
select throws_ok(format($$ select public.register_library_copy(%L, %L, 'T-2', 'T-2') $$, :'title_y', :'johar_id'), 'CAMPUS_NOT_ALLOWED', 'a librarian cannot register copies for a campus they do not serve');

select * from finish();
rollback;
