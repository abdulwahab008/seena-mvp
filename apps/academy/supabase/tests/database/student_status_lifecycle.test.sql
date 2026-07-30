-- pgTAP tests for FR-C12: student status lifecycle transitions.
begin;
select plan(10);

select public.provision_tenant('test-status-co', 'Status Co', 'owner@statusco.test');
select id as tenant_id from public.tenant where slug = 'test-status-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_student(:'campus_id'::uuid, 'Ayesha Noor', '2014-01-01'::date, 'female') as student_id \gset

-- ── illegal direct transition ────────────────────────────────────────

select public.fn_change_student_status(:'student_id'::uuid, 'graduated', 'graduation');
select throws_ok(
  format($$ select public.fn_change_student_status(%L, 'active', 'other') $$, :'student_id'),
  'ILLEGAL_STATUS_TRANSITION',
  'graduated -> active directly is not a legal transition — only readmission reactivates'
);

-- ── readmission IS a legal (Principal-gated) path back ────────────────

select public.fn_change_student_status(:'student_id'::uuid, 'active', 'readmission');
select is(
  (select status from public.student where id = :'student_id'),
  'active'::public.student_status,
  'readmission (graduated -> active) is the legal path back, and it succeeds as owner (a superset of principal)'
);

-- ── transfer requires a document unless explicitly waived ─────────────

select throws_ok(
  format($$ select public.fn_change_student_status(%L, 'transferred', 'transfer_out') $$, :'student_id'),
  'DOCUMENT_REQUIRED',
  'transferring without waiving the document requirement is rejected'
);
select public.fn_change_student_status(
  :'student_id'::uuid, 'transferred', 'transfer_out', current_date, 'TC pending, family relocating urgently', true
);
select is(
  (select status from public.student where id = :'student_id'),
  'transferred'::public.student_status,
  'transferring with the waiver flag set succeeds'
);
select is(
  (select reason_note from public.student_status_history where student_id = :'student_id' and to_status = 'transferred'),
  'TC pending, family relocating urgently [document requirement waived]',
  'the waiver is recorded on the history row alongside the reason'
);

-- ── every transition lands a history row ──────────────────────────────

select is(
  (select count(*)::int from public.student_status_history where student_id = :'student_id'),
  3,
  'three transitions so far (active->graduated, graduated->active, active->transferred) produced three history rows'
);

-- ── role gate: a subject teacher cannot change status ─────────────────

select public.create_student(:'campus_id'::uuid, 'Bilal Anwar', '2014-01-01'::date, 'male') as student2_id \gset
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$ select public.fn_change_student_status(%L, 'graduated', 'graduation') $$, :'student2_id'),
  'FORBIDDEN',
  'a subject teacher cannot action a status transition that requires the principal role'
);
-- active -> inactive requires no role, so a subject teacher CAN do this one.
select lives_ok(
  format($$ select public.fn_change_student_status(%L, 'inactive', 'other') $$, :'student2_id'),
  'a subject teacher CAN action a transition with no role requirement (active -> inactive)'
);

-- ── overdue on_leave detection ──────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select public.create_student(:'campus_id'::uuid, 'Sara Khalid', '2014-01-01'::date, 'female') as leave_student_id \gset
select public.fn_change_student_status(:'leave_student_id'::uuid, 'on_leave', 'medical');
select is(
  (select count(*)::int from public.fn_find_overdue_leave_students() where student_id = :'leave_student_id'),
  0,
  'a student who just went on leave today is not yet overdue'
);

reset role;
update public.student_status_history set effective_date = current_date - 61 where student_id = :'leave_student_id' and to_status = 'on_leave';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.fn_find_overdue_leave_students() where student_id = :'leave_student_id'),
  1,
  'a student on_leave for 61 days is flagged as overdue for review'
);

select * from finish();
rollback;
