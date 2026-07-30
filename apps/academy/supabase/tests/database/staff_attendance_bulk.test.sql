-- pgTAP tests for FR-D07: manual daily staff attendance marking.
begin;
select plan(9);

select public.provision_tenant('test-attendance-co', 'Attendance Co', 'owner@attendanceco.test');
select id as tenant_id from public.tenant where slug = 'test-attendance-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_staff(:'campus_id'::uuid, 'Present Teacher', 'female', p_cnic => '4210112340021') as present_id \gset
select public.create_staff(:'campus_id'::uuid, 'Absent Teacher', 'male', p_cnic => '4210112340022') as absent_id \gset
select public.create_staff(:'campus_id'::uuid, 'On Leave Teacher', 'female', p_cnic => '4210112340023') as leave_staff_id \gset
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.fn_grant_leave_balance(:'leave_staff_id'::uuid, :'casual_id'::uuid, 5.00);
select public.apply_for_leave(:'leave_staff_id'::uuid, :'casual_id'::uuid, '2026-07-29'::date, '2026-07-29'::date) as leave_app_id \gset
select public.fn_decide_leave_application(:'leave_app_id'::uuid, 'approved');

-- ── one RPC writes the whole sheet in a single transaction ────────────

select public.mark_staff_attendance_bulk(
  :'campus_id'::uuid, '2026-07-29'::date,
  jsonb_build_array(
    jsonb_build_object('staff_id', :'present_id', 'status', 'present'),
    jsonb_build_object('staff_id', :'absent_id', 'status', 'absent', 'remarks', 'called in sick')
  )
) as mark_result \gset
select is(
  ((:'mark_result')::jsonb ->> 'written')::int,
  2,
  'a two-row sheet writes exactly 2 rows in one call'
);
select is(
  (select count(*)::int from public.staff_attendance where campus_id = :'campus_id' and att_date = '2026-07-29'),
  3,
  '3 rows exist for the day: 2 just marked manually, 1 already seeded by the leave approval'
);

-- ── upsert on (staff_id, att_date): saving again does not duplicate ───

select public.mark_staff_attendance_bulk(
  :'campus_id'::uuid, '2026-07-29'::date,
  jsonb_build_array(jsonb_build_object('staff_id', :'absent_id', 'status', 'present'))
);
select is(
  (select count(*)::int from public.staff_attendance where staff_id = :'absent_id' and att_date = '2026-07-29'),
  1,
  'marking the same staff member again on the same date upserts, not duplicates'
);
select is(
  (select status from public.staff_attendance where staff_id = :'absent_id' and att_date = '2026-07-29'),
  'present'::public.attendance_status,
  'the corrected status is what is now on the row'
);

-- ── LEAVE_LOCKED: a manual attempt to override a leave-sourced row is skipped, not written ─

select public.mark_staff_attendance_bulk(
  :'campus_id'::uuid, '2026-07-29'::date,
  jsonb_build_array(jsonb_build_object('staff_id', :'leave_staff_id', 'status', 'absent'))
) as locked_result \gset
select is(
  ((:'locked_result')::jsonb -> 'locked_staff_ids' -> 0)::text,
  ('"' || :'leave_staff_id' || '"'),
  'the leave-locked staff member is reported back in locked_staff_ids'
);
select is(
  (select status from public.staff_attendance where staff_id = :'leave_staff_id' and att_date = '2026-07-29'),
  'on_leave'::public.attendance_status,
  'the on_leave row is untouched — the manual "absent" attempt never landed'
);
select is(
  (select source from public.staff_attendance where staff_id = :'leave_staff_id' and att_date = '2026-07-29'),
  'leave'::public.attendance_source,
  'the source is still leave, not overwritten to manual'
);

-- ── 7-day correction window: HR blocked, Principal allowed ───────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format(
    $$ select public.mark_staff_attendance_bulk(%L, (current_date - 8)::date, jsonb_build_array(jsonb_build_object('staff_id', %L, 'status', 'present'))) $$,
    :'campus_id', :'present_id'
  ),
  'CORRECTION_WINDOW_EXPIRED',
  'an HR Manager editing attendance 8 days old is rejected'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select lives_ok(
  format(
    $$ select public.mark_staff_attendance_bulk(%L, (current_date - 8)::date, jsonb_build_array(jsonb_build_object('staff_id', %L, 'status', 'present'))) $$,
    :'campus_id', :'present_id'
  ),
  'the same 8-day-old edit succeeds for a Principal — the correction window does not bind them'
);

select * from finish();
rollback;
