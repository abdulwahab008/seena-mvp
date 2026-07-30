-- pgTAP tests for FR-D10 (leave balance ledger) and FR-D11 (leave
-- application with atomic balance hold).
begin;
select plan(11);

select public.provision_tenant('test-leave-co', 'Leave Co', 'owner@leaveco.test');
select id as tenant_id from public.tenant where slug = 'test-leave-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

select public.create_staff(:'campus_id'::uuid, 'Casual Teacher', 'female', p_cnic => '4210112345678') as staff_id \gset
select public.create_leave_type('CASUAL', 'Casual Leave', 10) as casual_id \gset
select public.fn_grant_leave_balance(:'staff_id'::uuid, :'casual_id'::uuid, 3.00);

-- ── D10: balance reads as the ledger sum ────────────────────────────

select is(
  public.fn_leave_balance(:'staff_id'::uuid, :'casual_id'::uuid),
  3.00,
  'the balance after a 3-day grant and nothing else is exactly 3.00'
);

-- ── D11: working_days_between excludes Sundays and holidays ─────────

-- 2026-06-05 (Fri) to 2026-06-11 (Thu) = 7 calendar days, one Sunday
-- (06-07). Add two gazetted holidays inside the range to match the AC.
select public.add_holiday('2026-06-09'::date, 'Test Holiday 1', :'campus_id'::uuid);
select public.add_holiday('2026-06-10'::date, 'Test Holiday 2', :'campus_id'::uuid);
select is(
  public.working_days_between(:'campus_id'::uuid, '2026-06-05'::date, '2026-06-11'::date),
  4.00,
  '7 calendar days minus 1 Sunday minus 2 gazetted holidays leaves exactly 4 working days'
);

-- ── D11: insufficient balance is rejected with the available amount ──

select throws_ok(
  format(
    $$ select public.apply_for_leave(%L, %L, '2026-06-01'::date, '2026-06-04'::date) $$,
    :'staff_id', :'casual_id'
  ),
  'INSUFFICIENT_BALANCE',
  'a 4-working-day application against a 3.00 balance is rejected (2026-06-01 to 06-04 is Mon-Thu, no Sunday, 4 working days)'
);

-- ── D11: a valid application holds the balance without consuming it ──

select public.apply_for_leave(:'staff_id'::uuid, :'casual_id'::uuid, '2026-06-01'::date, '2026-06-02'::date) as app_id \gset
select is(
  public.fn_leave_balance(:'staff_id'::uuid, :'casual_id'::uuid),
  1.00,
  'a 2-day hold against a 3.00 balance leaves 1.00 available — held, not yet consumed'
);
select is(
  (select status from public.leave_application where id = :'app_id'),
  'pending'::public.leave_application_status,
  'the application itself is pending, awaiting a decision'
);

-- ── D11: half-day holds exactly 0.50 ────────────────────────────────

select public.apply_for_leave(:'staff_id'::uuid, :'casual_id'::uuid, '2026-06-03'::date, '2026-06-03'::date, true) as half_day_app_id \gset
select is(
  (select working_days from public.leave_application where id = :'half_day_app_id'),
  0.50,
  'a half-day application holds exactly 0.50 days'
);

-- ── D11: rejection reverses the hold in the same transaction ────────

select public.fn_decide_leave_application(:'half_day_app_id'::uuid, 'rejected', 'coverage unavailable that day');
select is(
  public.fn_leave_balance(:'staff_id'::uuid, :'casual_id'::uuid),
  1.00,
  'rejecting the half-day application restores the balance to 1.00 (the 0.50 hold is reversed, not lost)'
);

-- ── D11: approval consumes the hold and writes staff_attendance ─────

select public.fn_decide_leave_application(:'app_id'::uuid, 'approved');
select is(
  public.fn_leave_balance(:'staff_id'::uuid, :'casual_id'::uuid),
  1.00,
  'approving the 2-day application still leaves 1.00 — the hold converts to a consumption, net balance unchanged'
);
select is(
  (select count(*)::int from public.staff_attendance where staff_id = :'staff_id' and att_date between '2026-06-01' and '2026-06-02'),
  2,
  'approval writes 2 staff_attendance rows (2026-06-01 and 06-02), both on_leave'
);
select is(
  (select array_agg(distinct source) from public.staff_attendance where staff_id = :'staff_id' and att_date between '2026-06-01' and '2026-06-02'),
  array['leave']::public.attendance_source[],
  'both rows carry source=leave'
);

-- ── an already-decided application cannot be decided again ──────────

select throws_ok(
  format($$ select public.fn_decide_leave_application(%L, 'approved') $$, :'app_id'),
  'APPLICATION_NOT_PENDING',
  'deciding an already-approved application a second time is rejected'
);

select * from finish();
rollback;
