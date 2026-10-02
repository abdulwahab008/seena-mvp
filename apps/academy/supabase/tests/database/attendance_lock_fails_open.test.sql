-- pgTAP tests for 20260801040000_attendance_lock_fails_open.sql.
--
-- The defect: is_attendance_locked() (FR-G09) reads its lock window
-- through resolve_attendance_policy(), which
-- 20260731770000_security_definer_campus_scope_audit.sql taught to
-- return NULL for a campus outside the CALLER's campus_ids claim — and
-- then did `if v_policy is null then return false`, i.e. reported a
-- long-locked day as OPEN. It has no role or campus check of its own on
-- purpose (the lock is a property of the section, not of who is asking)
-- and it is granted to authenticated, so it is directly RPC-reachable.
--
-- Every assertion below that names "reads as locked" FAILS against the
-- pre-fix function — it returned false in each of these cases.
--
-- Three populations are covered: a caller scoped to another campus, a
-- caller with the ordinary empty '{}' claim (a teacher with no
-- user_campus row — `not (campus = any('{}'))` is true for EVERY
-- campus), and a section whose campus has no policy at all, where
-- "cannot resolve the window" used to mean "open".
begin;
select plan(17);

select public.provision_tenant('test-att-lock-scope-co', 'Attendance Lock Scope Co', 'owner@attlockscope.test');
select id as tenant_id from public.tenant where slug = 'test-att-lock-scope-co' \gset
select id as campus_a_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@attlockscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Lock Owner');

-- Ms Sana is class teacher of a section at campus South. FR-G02
-- authorizes her by section_class_teacher, never by campus.
select gen_random_uuid() as sana_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'sana_uid', 'sana@attlockscope.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'sana_uid', :'tenant_id', 'class_teacher', 'Ms Sana');

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus South', 'SOUTH') returning id as campus_b_id \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus West', 'WEST') returning id as campus_c_id \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id', :'campus_c_id'), 'sub', :'owner_uid')::text,
  true
);

select public.create_section(:'campus_a_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Alpha', 40) as section_alpha \gset
select public.create_section(:'campus_b_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Zulu', 40) as section_zulu \gset
select public.create_section(:'campus_c_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'Whisky', 40) as section_whisky \gset

-- A 24h window makes both fixtures time-of-day independent: today's
-- deadline is always tomorrow 08:00, and a date 30 days ago is always
-- long past. Campus West deliberately gets NO policy.
select public.set_attendance_policy(p_campus_id => :'campus_a_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);
select public.set_attendance_policy(p_campus_id => :'campus_b_id'::uuid, p_session_id => :'session_id'::uuid, p_lock_window_hours => 24);

select public.assign_class_teacher(:'section_zulu'::uuid, :'sana_uid'::uuid, current_date - 90);

-- ── Ms Sana, claim = campus A only, asking about her campus B section ──

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'sana_uid')::text,
  true
);

select is(
  public.is_attendance_locked(:'section_zulu'::uuid, (current_date - 30)::date),
  true,
  'AC1: a date whose window elapsed 30 days ago reads as LOCKED for a caller scoped to a different campus — the lock control no longer fails open'
);
select is(
  public.is_attendance_locked(:'section_zulu'::uuid, current_date),
  false,
  'and today, still inside the 24h window, correctly reads as open for that same caller — the fix is not a blanket "everything is locked"'
);
select is(
  (public.resolve_attendance_lock_info(:'section_zulu'::uuid, (current_date - 30)::date) ->> 'locked')::boolean,
  true,
  'AC3: the register banner agrees — the locked day is reported as locked'
);
select isnt(
  (public.resolve_attendance_lock_info(:'section_zulu'::uuid, (current_date - 30)::date) ->> 'locked_at'),
  null,
  'and it carries the real elapsed deadline, not a banner with no time on it'
);

-- ── The same defect with no second campus in sight ─────────────────────
-- A teacher with no user_campus row claims '{}', which contains no
-- campus at all, so the guard blanked the policy for her OWN campus.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(), 'sub', :'sana_uid')::text,
  true
);
select is(
  public.is_attendance_locked(:'section_zulu'::uuid, (current_date - 30)::date),
  true,
  'a teacher whose campus_ids claim is empty gets the true lock state for her own section, on every date'
);
select is(
  public.is_attendance_locked(:'section_zulu'::uuid, current_date),
  false,
  'and today still reads as open for her too'
);

-- ── An unresolvable policy is no longer "open" ─────────────────────────
-- Campus West has no attendance_policy at all. Its register cannot be
-- written (save_attendance_register raises POLICY_NOT_CONFIGURED), so
-- reporting it as open was both unsafe and untrue.

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a_id', :'campus_b_id', :'campus_c_id'), 'sub', :'owner_uid')::text,
  true
);
select is(
  public.is_attendance_locked(:'section_whisky'::uuid, current_date),
  true,
  'a section whose campus and session have no attendance policy reads as locked — an unresolvable window never silently means "open"'
);
select is(
  (public.resolve_attendance_lock_info(:'section_whisky'::uuid, current_date) ->> 'locked')::boolean,
  true,
  'and the banner says so rather than offering a Save control that cannot succeed'
);

-- ── Nothing regressed for an ordinary, fully scoped caller ─────────────

select is(
  public.is_attendance_locked(:'section_alpha'::uuid, current_date),
  false,
  'an Owner scoped to every campus still sees today as open'
);
select is(
  public.is_attendance_locked(:'section_alpha'::uuid, (current_date - 30)::date),
  true,
  'and still sees a long-elapsed date as locked'
);
select is(
  public.is_attendance_locked(gen_random_uuid(), current_date),
  false,
  'a section id that does not exist is not a locked register — there is no register there at all'
);

-- ── A manual lock still short-circuits, and still only within tenant ───

select public.lock_attendance_now(:'section_alpha'::uuid, current_date);
select is(
  public.is_attendance_locked(:'section_alpha'::uuid, current_date),
  true,
  'AC3: an Owner forcing an early lock is still honoured ahead of the window elapsing'
);
select is(
  (public.resolve_attendance_lock_info(:'section_alpha'::uuid, current_date) ->> 'locked_by'),
  'manual',
  'and the banner still reports it as a manual lock with its recorded timestamp'
);

-- ── The audit's guard still holds for ordinary, direct callers ─────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_a_id'), 'sub', :'sana_uid')::text,
  true
);
select is(
  (select public.resolve_attendance_policy(:'campus_b_id'::uuid, :'session_id'::uuid)),
  null,
  'the campus guard is untouched: the SAME teacher calling resolve_attendance_policy() directly for campus B still gets NULL'
);
select is(
  (select count(*)::int from public.attendance_policy where campus_id = :'campus_b_id'::uuid),
  0,
  'and campus B''s policy rows are still unreadable to her directly — the lock decision discloses nothing she could fetch herself'
);
select isnt(
  (select public.resolve_attendance_policy(:'campus_a_id'::uuid, :'session_id'::uuid)),
  null,
  'while her own campus A still resolves normally through the public function'
);
select throws_ok(
  format($$ select app.resolve_attendance_policy_unscoped(%L::uuid, %L::uuid, %L::uuid) $$, :'tenant_id', :'campus_b_id', :'session_id'),
  '42501',
  null,
  'authenticated cannot call the unscoped policy resolver directly — the guard cannot be routed around'
);

select * from finish();
rollback;
