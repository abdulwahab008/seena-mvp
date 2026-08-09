-- pgTAP tests for 20260731770000_security_definer_campus_scope_audit.sql,
-- the follow-up audit to FR-A12 (per_campus_role_scoping.test.sql already
-- covers the 3 functions FR-A12 itself fixed: daily_collection_report,
-- build_collection_report_payload, finalise_cash_book_day).
--
-- Covers 4 of the 35 functions this migration added an
-- app.auth_campus_ids() guard to — chosen as the clearest, highest-impact
-- cases: create_student and create_staff (the two functions FR-A12's own
-- header named as suspected real holes), attach_staff_campus (a straight
-- privilege-escalation vector — it grants a staff member access to a
-- campus), and create_academic_session (the one function among the fixed
-- set with the NULL-means-tenant-wide special case, proving that path is
-- closed too, not just the explicit-campus-id path). Also proves the
-- public.campus RLS tightening (same migration) scopes the campus list to
-- the caller's own campuses for a non-owner role.
begin;
select plan(12);

select public.provision_tenant('test-secdef-audit-co', 'SecDef Audit Co', 'owner@secdefaudit.test');
select id as tenant_id from public.tenant where slug = 'test-secdef-audit-co' \gset
select id as campus1_id from public.campus where tenant_id = :'tenant_id' \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus 2', 'C2') returning id as campus2_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'owner',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id')
  )::text,
  true
);

-- An owner-created staff member at campus1, used by the attach_staff_campus
-- tests below.
select public.create_staff(:'campus1_id'::uuid, 'Existing Teacher', 'female', p_cnic => '4210112340099') as existing_staff_id \gset

-- ── principal scoped to campus1 only, for every FORBIDDEN/success pair ──
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus1_id'))::text,
  true
);

-- ── create_student: named in FR-A12's header as a suspected real gap ────

select throws_ok(
  format($$ select public.create_student(%L, 'Cross Campus Child', '2015-01-01'::date, 'male') $$, :'campus2_id'),
  'FORBIDDEN',
  'create_student: a principal scoped to campus1 only cannot create a student directly in campus2'
);

select public.create_student(:'campus1_id'::uuid, 'Own Campus Child', '2015-01-01'::date, 'female') as own_student_id \gset
select is(
  (select campus_id from public.student where id = :'own_student_id'),
  :'campus1_id'::uuid,
  'create_student: the same principal can still create a student in their own campus1'
);

-- ── create_staff: the other function FR-A12's header named ──────────────

select throws_ok(
  format($$ select public.create_staff(%L, 'Cross Campus Hire', 'male', p_cnic => '4210112340100') $$, :'campus2_id'),
  'FORBIDDEN',
  'create_staff: a principal scoped to campus1 only cannot hire staff directly into campus2'
);

select public.create_staff(:'campus1_id'::uuid, 'Own Campus Hire', 'male', p_cnic => '4210112340101') as own_staff_id \gset
select is(
  (select campus_id from public.staff where id = :'own_staff_id'),
  :'campus1_id'::uuid,
  'create_staff: the same principal can still hire staff into their own campus1'
);

-- ── attach_staff_campus: a straight privilege-escalation vector — it
--    grants the staff member row-level access to the target campus, so an
--    unchecked p_campus_id lets a principal expand ANY staff member's
--    scope into a campus that principal doesn't even manage ─────────────

select throws_ok(
  format($$ select public.attach_staff_campus(%L, %L) $$, :'existing_staff_id', :'campus2_id'),
  'FORBIDDEN',
  'attach_staff_campus: a principal scoped to campus1 only cannot grant a staff member access to campus2'
);
select ok(
  not exists (select 1 from public.staff_campus where staff_id = :'existing_staff_id' and campus_id = :'campus2_id'),
  'attach_staff_campus: the rejected call left no staff_campus row for campus2 behind'
);

select public.attach_staff_campus(:'existing_staff_id'::uuid, :'campus1_id'::uuid);
select ok(
  exists (select 1 from public.staff_campus where staff_id = :'existing_staff_id' and campus_id = :'campus1_id'),
  'attach_staff_campus: the same principal can still attach that staff member to their own campus1'
);

-- ── create_academic_session: the fixed set's one NULL-means-tenant-wide
--    case — proves a non-owner can't bypass the scope check by omitting
--    p_campus_id, not just that an explicit out-of-scope id is rejected ──

select throws_ok(
  format($$ select public.create_academic_session(%L, 'Cross Campus Term', '2035-01-01'::date, '2035-06-01'::date) $$, :'campus2_id'),
  'FORBIDDEN',
  'create_academic_session: a principal scoped to campus1 only cannot create a session in campus2'
);
select throws_ok(
  $$ select public.create_academic_session(null, 'Tenant Wide Term', '2035-01-01'::date, '2035-06-01'::date) $$,
  'FORBIDDEN',
  'create_academic_session: the same principal cannot bypass the scope check by passing a null (tenant-wide) campus id either'
);
select public.create_academic_session(:'campus1_id'::uuid, 'Own Campus Term', '2035-01-01'::date, '2035-06-01'::date) as own_session_id \gset
select is(
  (select campus_id from public.academic_session where id = :'own_session_id'),
  :'campus1_id'::uuid,
  'create_academic_session: the same principal can still create a session in their own campus1'
);

-- ── public.campus SELECT RLS: same migration scopes this to the caller's
--    own campuses for non-owner/super_admin roles ───────────────────────

select is(
  (select count(*)::int from public.campus),
  1,
  'campus RLS: a principal scoped to campus1 only sees 1 campus row, not both tenant campuses'
);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id', 'app_role', 'owner',
    'campus_ids', json_build_array(:'campus1_id', :'campus2_id')
  )::text,
  true
);
select is(
  (select count(*)::int from public.campus),
  2,
  'campus RLS: an owner still sees every tenant campus, exempt from the scope filter same as every other fixed function'
);

select * from finish();
rollback;
