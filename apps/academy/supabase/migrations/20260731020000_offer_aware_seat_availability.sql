-- FR-B06 (seat capacity per class): app.fn_available_seats currently
-- subtracts only confirmed ('active') enrolments from section capacity,
-- never live admission offers — so two officers issuing offers for the
-- last seat in quick succession both succeed, and the double-booking is
-- only discovered when the second family actually tries to enrol.
--
-- Scope cut: FR-B06's own Notion spec describes a standalone
-- class_seat_capacity table (total_seats/reserved_seats, admin-settable
-- independent of section capacity) with a sibling-priority reserved pool.
-- That is NOT built here. class_section.capacity (FR-E02/E03) is already
-- this tenant's live, tested source of truth for how many seats a class
-- has — summed across its active sections. A second, independently-settable
-- "total_seats" number alongside it would give the system two capacity
-- figures that can silently disagree. This migration closes the concrete,
-- provable gap instead: an issued-but-undecided offer must count against
-- availability exactly like a confirmed enrolment does, because it is
-- provisionally holding the seat. A genuine "hold back N seats from
-- day-one admissions for transfers later in the year" feature is a real,
-- separate ask that deserves its own deliberate design, not a byproduct of
-- this fix. Reserved-quota administration is deferred with it.
--
-- The offer side of the check reads "status = 'issued' and expires_at >
-- now()", not "status = 'issued'" alone: fn_expire_offers() (FR-B16) is a
-- callable, not cron-scheduled function (no pg_cron locally), so a
-- past-due offer can sit with status still 'issued' for a while.
-- Availability must not stay pinned at 0 for that whole window — an offer
-- whose clock has already run out never holds a seat, whether or not the
-- sweep has physically flipped its row yet.
--
-- Also hardened while rewriting this function's body: the original had no
-- tenant_id filter on any of the three subqueries at all, relying only on
-- its caller (fn_issue_offer et al.) to have already resolved trustworthy
-- ids. Cheap to close here since the whole body is already being replaced;
-- the same missing-tenant-check shape elsewhere in this file is flagged
-- separately, not fixed as a drive-by in this migration.

create or replace function app.fn_available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(cs.capacity), 0)::int
       - (
           select count(*)::int from public.enrolment e
            where e.class_level_id = p_class_level_id and e.session_id = p_session_id
              and e.tenant_id = app.auth_tenant_id() and e.status = 'active'
         )
       - (
           select count(*)::int
             from public.admission_offer o
             join public.admission_application a on a.id = o.application_id
            where a.class_applied_id = p_class_level_id
              and a.session_id = p_session_id
              and a.campus_id = p_campus_id
              and a.tenant_id = app.auth_tenant_id()
              and o.status = 'issued'
              and o.expires_at > now()
         )
    from public.class_section cs
   where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.campus_id = p_campus_id
     and cs.tenant_id = app.auth_tenant_id() and cs.is_active;
$$;

-- Read-only, side-effect-free peek at the same number fn_issue_offer()
-- checks internally — the officer-facing "N seats left" / disabled Issue
-- Offer control (FR-B06's AC) needs a way to ask without issuing.
create or replace function public.available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_available_seats(p_class_level_id, p_session_id, p_campus_id);
$$;

revoke execute on function public.available_seats(uuid, uuid, uuid) from public, anon;
grant execute on function public.available_seats(uuid, uuid, uuid) to authenticated;
