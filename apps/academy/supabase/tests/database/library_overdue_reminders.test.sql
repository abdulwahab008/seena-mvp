begin;
select plan(5);

select public.provision_tenant('test-lib-overdue', 'Library Overdue Co', 'owner@liboverdue.test') as tenant_id \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_id', 'GR-L1', 'Reader One', '2014-01-01', 'female', 'active') returning id as kid \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, status)
values (:'tenant_id', :'campus_id', 'GR-L2', 'Reader Two', '2014-01-01', 'male', 'active') returning id as kid2 \gset
insert into public.guardian (tenant_id, name_en, phone_e164) values (:'tenant_id', 'Mother One', '+923007770001') returning id as mum \gset
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing, receives_academic)
values (:'tenant_id', :'kid', :'mum', 'mother', true, true, true);
insert into public.library_title (tenant_id, title) values (:'tenant_id', 'Physics 9') returning id as title_id \gset
insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode) select :'tenant_id', :'campus_id', :'title_id', 'ACC-' || n, 'BC' || n from generate_series(1, 3) n;
insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, due_on, policy_snapshot)
select :'tenant_id', :'campus_id', id, :'kid', 'student', current_date - 3, '{}' from public.library_copy where tenant_id = :'tenant_id' and barcode = 'BC1';
insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, due_on, policy_snapshot)
select :'tenant_id', :'campus_id', id, :'kid', 'student', current_date + 3, '{}' from public.library_copy where tenant_id = :'tenant_id' and barcode = 'BC2';
insert into public.library_loan (tenant_id, campus_id, copy_id, borrower_id, borrower_role, due_on, policy_snapshot)
select :'tenant_id', :'campus_id', id, :'kid2', 'student', current_date - 1, '{}' from public.library_copy where tenant_id = :'tenant_id' and barcode = 'BC3';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.queue_library_overdue_messages(:'campus_id'), '{"queued": 1, "no_phone": 1}'::jsonb, 'one reminder for the overdue book; a borrower with no parent phone is counted');
select is((public.queue_library_overdue_messages(:'campus_id') ->> 'queued')::int, 0, 'never twice the same day');
reset role;
select matches((select body from public.message where tenant_id = :'tenant_id' and idempotency_key like 'library-overdue:%'), '"Physics 9", which was due on', 'the message names the book and due date');
select is((select count(*)::int from public.message where tenant_id = :'tenant_id' and idempotency_key like 'library-overdue:%'), 1, 'a book not yet due is not chased');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.queue_library_overdue_messages(%L) $$, :'campus_id'), '42501', 'FORBIDDEN', 'a teacher cannot send library reminders');

select * from finish();
rollback;
