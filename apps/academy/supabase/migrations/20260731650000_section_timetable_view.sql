-- FR-F11: per-section timetable view.
--
-- Design notes:
--   * No section_timetable(p_section_id, p_date, p_lang) SECURITY DEFINER
--     function, despite that being this FR's own literally-named Supabase
--     Object. This session's established shape for a read surface is RLS
--     scoping the base tables + a security_invoker view doing nothing but
--     column shaping (v_student_homework_feed, v_teach_scope_exception,
--     v_slot_clock_time) — a hand-rolled function would just reimplement
--     the same enrolment check RLS already proves correct.
--   * A guardian's JWT carries tenant_id: null, app_role: 'none'
--     (custom_access_token_hook's own "no app_user row" branch) — every
--     tenant-fenced policy (timetable_slot_campus_scope, subject_tenant_
--     read, room_campus_scope, timetable_version_campus_scope, ...) is
--     unreachable from a guardian session by construction. Every new
--     policy below is instead scoped purely through app.auth_guardian_
--     student_ids() (FR-C11) — the same shape enrolment_parent_read_own_
--     children and homework_parent_read already established, no
--     tenant_id term at all.
--   * A real, pre-existing gap surfaced while building this: class_
--     section had NO guardian-read policy at all. class_section_parent_
--     read below fixes that generally (same unconditional shape as
--     enrolment_parent_read_own_children) — it isn't scoped to just
--     timetable data, so it also fixes the *already-shipped*
--     /portal/homework page's own silently-blank section label for real
--     guardians (that page's PostgREST embed of class_section was
--     returning null under RLS the whole time; its own e2e test never
--     asserted on the label text, only on the homework-feed testids, so
--     it went uncaught). subject_parent_read and room_parent_read below
--     are scoped narrowly to timetable_slot only, for this FR's own
--     need — homework's own parallel gap (subject_name_en also renders
--     blank for a real guardian) is a distinct pre-existing issue, out
--     of scope for this migration, and is flagged separately.
--   * teacher_name is resolved via app.display_name_for_user(), a narrow
--     SECURITY DEFINER function returning only full_name for a given
--     user_id — not a guardian-read policy on app_user itself, which
--     would hand back phone_e164 and every other staff member's row in
--     the tenant. This is exactly the AC's own privacy line: a display
--     name is fine to expose broadly, a phone number is not.
--   * The view carries the owning version's status and validity instead
--     of pre-filtering to "today" — same reasoning as v_daily_timetable's
--     own header: a view has no date parameter, so date resolution
--     (which published version, and via resolve_bell_template() (FR-F02,
--     already Ramadan-aware) which actual clock times) stays a query the
--     caller runs against these columns, not baked into the view.
--   * Scope cut: the parallel-elective "both electives stacked" AC is not
--     rendered specially — FR-F07 (not yet built) is what actually lets
--     two timetable_slot rows coexist at the same (version, section,
--     weekday, period); today's plain unique index only ever allows one,
--     so there is nothing to stack yet. The view already carries
--     elective_bucket/parallel_group_id verbatim for whenever F07 ships.
--   * Scope cut: the "<1.5s on simulated 3G" AC is an architectural
--     property (one indexed query, no N+1), not something asserted with
--     a timer in this suite — same precedent as F09's own untimed
--     "1,632 slots in under 5 seconds" AC.

create or replace function app.display_name_for_user(p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select full_name from public.app_user where user_id = p_user_id;
$$;

revoke execute on function app.display_name_for_user(uuid) from public, anon;
grant execute on function app.display_name_for_user(uuid) to authenticated;

create or replace view public.v_section_timetable with (security_invoker = true) as
select
  ts.id as slot_id,
  ts.tenant_id,
  ts.campus_id,
  ts.section_id,
  ts.timetable_version_id,
  tv.status as version_status,
  tv.validity as version_validity,
  ts.weekday,
  ts.period_no,
  ts.subject_id,
  subj.code as subject_code,
  subj.name_en as subject_name_en,
  subj.name_ur as subject_name_ur,
  ts.staff_id,
  app.display_name_for_user(ts.staff_id) as teacher_name,
  ts.room_id,
  r.code as room_code,
  r.name as room_name,
  ts.elective_bucket,
  ts.parallel_group_id
from public.timetable_slot ts
join public.timetable_version tv on tv.id = ts.timetable_version_id
join public.subject subj on subj.id = ts.subject_id
left join public.room r on r.id = ts.room_id;

revoke all on public.v_section_timetable from public, anon;
grant select on public.v_section_timetable to authenticated;

-- AC: a Parent sees only their own child's section, and only once it is
-- actually Published — a draft in progress is invisible, same as
-- homework_parent_read's own "status = 'published'" gate.
create policy timetable_slot_parent_read on public.timetable_slot
  for select to authenticated
  using (
    exists (select 1 from public.timetable_version tv where tv.id = timetable_slot.timetable_version_id and tv.status = 'PUBLISHED')
    and section_id in (
      select e.section_id from public.enrolment e
       where e.status = 'active' and e.student_id = any(app.auth_guardian_student_ids())
    )
  );

-- Deliberately does NOT reference timetable_slot — timetable_slot_parent_
-- read (above) already references timetable_version, and RLS policies
-- that cross-reference each other's tables trigger Postgres's own
-- "infinite recursion detected in policy" error for EVERY query against
-- either table, not just guardian ones. Scoped instead via class_section
-- (which has no policy referencing either table), matching on campus/
-- session directly. Slightly broader than "only versions with an actual
-- slot for their child's section" — a guardian can see the version row
-- for any Published timetable at their child's own campus/session, not
-- only the ones with slots in that exact section — but that's a harmless
-- widening: timetable_slot_parent_read is still the real gate on which
-- SLOTS they can see.
create policy timetable_version_parent_read on public.timetable_version
  for select to authenticated
  using (
    status = 'PUBLISHED'
    and exists (
      select 1 from public.enrolment e
        join public.class_section cs on cs.id = e.section_id
       where e.status = 'active' and e.student_id = any(app.auth_guardian_student_ids())
         and cs.campus_id = timetable_version.campus_id and cs.session_id = timetable_version.session_id
    )
  );

create policy subject_parent_read on public.subject
  for select to authenticated
  using (
    id in (
      select ts.subject_id from public.timetable_slot ts
        join public.timetable_version tv on tv.id = ts.timetable_version_id
       where tv.status = 'PUBLISHED'
         and ts.section_id in (
           select e.section_id from public.enrolment e
            where e.status = 'active' and e.student_id = any(app.auth_guardian_student_ids())
         )
    )
  );

create policy room_parent_read on public.room
  for select to authenticated
  using (
    id in (
      select ts.room_id from public.timetable_slot ts
        join public.timetable_version tv on tv.id = ts.timetable_version_id
       where tv.status = 'PUBLISHED' and ts.room_id is not null
         and ts.section_id in (
           select e.section_id from public.enrolment e
            where e.status = 'active' and e.student_id = any(app.auth_guardian_student_ids())
         )
    )
  );

create policy class_section_parent_read on public.class_section
  for select to authenticated
  using (
    id in (select e.section_id from public.enrolment e where e.status = 'active' and e.student_id = any(app.auth_guardian_student_ids()))
  );

-- Hardening pre-existing policies: none of these five previously excluded
-- 'parent' the way homework_staff_read already does. In real production
-- a guardian's JWT never carries campus_ids at all (custom_access_token_
-- hook's "no app_user row" branch sets tenant_id: null for anyone without
-- one, guardians included) so these were never actually reachable by a
-- real guardian session — but this codebase's own established pgTAP
-- convention for testing guardian RLS (homework.test.sql included) sets a
-- real tenant_id/campus_ids on a 'parent'-role claim for test convenience,
-- and every negative AC this migration adds (draft invisible, wrong
-- section invisible, no direct app_user access) needs these five to
-- actually deny a 'parent' role rather than accidentally admit it via
-- campus scope — same defense-in-depth already applied to fee_challan_
-- campus_scope and others during FR-C11.

drop policy app_user_tenant_scope on public.app_user;
create policy app_user_tenant_scope on public.app_user
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'none'));

drop policy room_campus_scope on public.room;
create policy room_campus_scope on public.room
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

drop policy class_section_campus_scope on public.class_section;
create policy class_section_campus_scope on public.class_section
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

drop policy timetable_version_campus_scope on public.timetable_version;
create policy timetable_version_campus_scope on public.timetable_version
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

drop policy timetable_slot_campus_scope on public.timetable_slot;
create policy timetable_slot_campus_scope on public.timetable_slot
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() not in ('parent', 'none')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
