-- FR-B07: waitlist with automatic promotion.
--
-- This is the exact gap the admissions-pipeline migration's own header
-- flagged and deferred: "B16's waitlist-promotion trigger needs FR-B07
-- (waitlist), which doesn't exist — a lapsed offer frees a seat but
-- promotes no one." Closed here: the trigger fires on an offer moving to
-- 'lapsed' OR 'declined' (both free a seat — 'accepted' does the
-- opposite, per app.fn_available_seats' own counting and the Module B
-- review fix earlier this session), promoting position 1 automatically.
--
-- Naming note: the FR's own Supabase Objects call the class column
-- "class_id" — renamed to class_level_id here to match every other
-- table in this schema (class_section, class_subject, ...); same
-- column, same meaning, just this codebase's actual convention.
--
-- Renumbering (AC: "positions 2-12 renumber to 1-11 with no gaps, no
-- duplicates") is done in two passes — set the affected rows to their
-- negative position, then flip them back positive — rather than a
-- deferred unique constraint (swap_class_level_ordinals' approach
-- elsewhere in this codebase): a partial unique index (scoped to
-- status = 'waiting', per the AC's own "released... no gaps" only
-- applying to currently-waiting rows) cannot also be DEFERRABLE in
-- Postgres — ALTER TABLE ... ADD CONSTRAINT UNIQUE has no WHERE clause,
-- and CREATE UNIQUE INDEX ... WHERE has no DEFERRABLE. The two-phase
-- negative/positive flip sidesteps the conflict entirely without
-- needing either.
--
-- fn_promote_waitlist_internal (app schema, no auth check) is the actual
-- logic, callable both from the trigger (which runs with no end-user JWT
-- when invoked from fn_expire_offers()'s service_role cron context) and
-- from the public, role-checked wrapper below (for an officer's manual
-- "check the waitlist now" action) — same split this codebase already
-- uses for app.fn_allocate_to_challan vs public.allocate_payment.
--
-- AC "two seats released within the same second by two different
-- transactions... two distinct applicants promoted, never twice" is
-- guaranteed by the advisory lock keyed on (campus, session, class), the
-- same pattern as every other race this codebase closes this way — not
-- independently re-provable in a single-connection pgTAP transaction.

create type public.waitlist_status as enum ('waiting', 'offer_pending', 'withdrawn');

create table public.admission_waitlist (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  session_id     uuid not null references public.academic_session(id) on delete cascade,
  class_level_id uuid not null references public.class_level(id),
  application_id uuid not null references public.admission_application(id) on delete cascade,
  position       int,
  status         public.waitlist_status not null default 'waiting',
  added_at       timestamptz not null default clock_timestamp(),
  removed_at     timestamptz,
  removal_reason text,
  removed_by     uuid references public.app_user(user_id),
  constraint uq_waitlist_application unique (application_id)
);

create unique index uq_waitlist_position on public.admission_waitlist (campus_id, session_id, class_level_id, position) where status = 'waiting';
create index idx_waitlist_campus_session_class_status on public.admission_waitlist (campus_id, session_id, class_level_id, status);

create trigger admission_waitlist_audit after insert or update or delete on public.admission_waitlist
  for each row execute function app.tg_audit_row();

create or replace function app.fn_renumber_waitlist(p_campus_id uuid, p_session_id uuid, p_class_level_id uuid)
returns void
language plpgsql
set search_path = ''
as $$
begin
  with ranked as (
    select id, row_number() over (order by position) as rn
      from public.admission_waitlist
     where campus_id = p_campus_id and session_id = p_session_id and class_level_id = p_class_level_id and status = 'waiting'
  )
  update public.admission_waitlist w set position = -ranked.rn from ranked where w.id = ranked.id;

  update public.admission_waitlist
     set position = -position
   where campus_id = p_campus_id and session_id = p_session_id and class_level_id = p_class_level_id
     and status = 'waiting' and position < 0;
end;
$$;

create or replace function public.join_waitlist(p_application_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app           public.admission_application%rowtype;
  v_next_position int;
  v_id            uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_app from public.admission_application where id = p_application_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_app.status not in ('submitted', 'under_review') then
    raise exception 'APPLICATION_NOT_WAITLISTABLE' using errcode = '55000';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('waitlist:' || v_app.campus_id::text || ':' || v_app.session_id::text || ':' || v_app.class_applied_id::text, 0)
  );

  select coalesce(max(position), 0) + 1 into v_next_position
    from public.admission_waitlist
   where campus_id = v_app.campus_id and session_id = v_app.session_id
     and class_level_id = v_app.class_applied_id and status = 'waiting';

  begin
    insert into public.admission_waitlist (tenant_id, campus_id, session_id, class_level_id, application_id, position)
    values (app.auth_tenant_id(), v_app.campus_id, v_app.session_id, v_app.class_applied_id, p_application_id, v_next_position)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception 'ALREADY_WAITLISTED' using errcode = '23505';
  end;

  return v_id;
end;
$$;

revoke execute on function public.join_waitlist(uuid) from public, anon;
grant execute on function public.join_waitlist(uuid) to authenticated;

-- Widened twice over from its original definition:
--
-- 1. An 'offer_pending' waitlist row holds the seat it was just promoted
--    into just as much as an issued/accepted offer does — without this,
--    fn_available_seats still reports the seat as free the instant it
--    promotes someone (no real admission_offer row exists for them yet),
--    and a second lapse arriving before the officer turns that
--    promotion into a real offer would promote a SECOND applicant for
--    the same one seat. The exact same double-booking shape as the
--    Module B review's own "an accepted offer still holds the seat" fix
--    earlier this session — closed here for the identical reason.
--
-- 2. Every subquery is now scoped by p_campus_id instead of
--    app.auth_tenant_id(): this function is called from the new offer-
--    lapse trigger below, which itself fires during fn_expire_offers()'s
--    service_role cron path — no end-user JWT, so app.auth_tenant_id()
--    resolves to NULL there and every tenant_id-filtered subquery would
--    silently count zero, under-reporting nothing as taken and
--    permanently returning NO_SEATS_AVAILABLE from the cron path. This
--    function's only two callers (fn_issue_offer, fn_reinstate_offer,
--    both already unchanged) already verify p_campus_id belongs to the
--    caller's own tenant before calling in — campus_id alone is already
--    as tenant-specific as tenant_id would be, without depending on a
--    JWT that may not exist.
create or replace function app.fn_available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(cs.capacity), 0)::int - (
    select count(*)::int from public.enrolment e
     where e.class_level_id = p_class_level_id and e.session_id = p_session_id
       and e.campus_id = p_campus_id and e.status = 'active'
  ) - (
    select count(*)::int
      from public.admission_offer o
      join public.admission_application a on a.id = o.application_id
     where a.class_applied_id = p_class_level_id
       and a.session_id = p_session_id
       and a.campus_id = p_campus_id
       and ((o.status = 'issued' and o.expires_at > now()) or o.status = 'accepted')
  ) - (
    select count(*)::int from public.admission_waitlist w
     where w.class_level_id = p_class_level_id and w.session_id = p_session_id and w.campus_id = p_campus_id
       and w.status = 'offer_pending'
  )
  from public.class_section cs
 where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.campus_id = p_campus_id
   and cs.is_active;
$$;

-- AC: a released seat promotes position 1 to 'offer_pending' and closes
-- up the remaining positions; an empty waitlist or no free seats is a
-- clean no-op, never an error.
create or replace function app.fn_promote_waitlist_internal(p_campus_id uuid, p_session_id uuid, p_class_level_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_available int;
  v_next      public.admission_waitlist%rowtype;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('waitlist:' || p_campus_id::text || ':' || p_session_id::text || ':' || p_class_level_id::text, 0)
  );

  v_available := app.fn_available_seats(p_class_level_id, p_session_id, p_campus_id);
  if v_available <= 0 then
    return jsonb_build_object('promoted', false, 'reason', 'NO_SEATS_AVAILABLE');
  end if;

  select * into v_next from public.admission_waitlist
   where campus_id = p_campus_id and session_id = p_session_id and class_level_id = p_class_level_id and status = 'waiting'
   order by position
   limit 1;

  if not found then
    return jsonb_build_object('promoted', false, 'reason', 'WAITLIST_EMPTY');
  end if;

  update public.admission_waitlist set status = 'offer_pending', position = null where id = v_next.id;
  perform app.fn_renumber_waitlist(p_campus_id, p_session_id, p_class_level_id);

  return jsonb_build_object('promoted', true, 'waitlist_id', v_next.id, 'application_id', v_next.application_id);
end;
$$;

create or replace function public.fn_promote_waitlist(p_campus_id uuid, p_session_id uuid, p_class_level_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  return app.fn_promote_waitlist_internal(p_campus_id, p_session_id, p_class_level_id);
end;
$$;

revoke execute on function public.fn_promote_waitlist(uuid, uuid, uuid) from public, anon;
grant execute on function public.fn_promote_waitlist(uuid, uuid, uuid) to authenticated;

-- AC: a manual withdrawal closes up lower positions and leaves an audit
-- trail (app.tg_audit_row(), already attached above, captures the
-- removal_reason on this same UPDATE).
create or replace function public.remove_from_waitlist(p_waitlist_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.admission_waitlist%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'REMOVAL_REASON_REQUIRED' using errcode = '23514';
  end if;

  select * into v_row from public.admission_waitlist where id = p_waitlist_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'WAITLIST_ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_row.status <> 'waiting' then
    raise exception 'NOT_WAITING' using errcode = '55000';
  end if;

  update public.admission_waitlist
     set status = 'withdrawn', removed_at = clock_timestamp(), removal_reason = p_reason, removed_by = auth.uid(), position = null
   where id = p_waitlist_id;

  perform app.fn_renumber_waitlist(v_row.campus_id, v_row.session_id, v_row.class_level_id);
end;
$$;

revoke execute on function public.remove_from_waitlist(uuid, text) from public, anon;
grant execute on function public.remove_from_waitlist(uuid, text) to authenticated;

create or replace function app.tg_offer_status_change_promote_waitlist()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_app public.admission_application%rowtype;
begin
  if old.status = new.status or new.status not in ('lapsed', 'declined') then
    return new;
  end if;

  select * into v_app from public.admission_application where id = new.application_id;
  if found then
    perform app.fn_promote_waitlist_internal(v_app.campus_id, v_app.session_id, new.class_level_id);
  end if;

  return new;
end;
$$;

create trigger trg_offer_status_change_promote_waitlist
  after update of status on public.admission_offer
  for each row execute function app.tg_offer_status_change_promote_waitlist();

alter table public.admission_waitlist enable row level security;

create policy waitlist_campus_scope on public.admission_waitlist
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
