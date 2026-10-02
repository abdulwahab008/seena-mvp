-- Module B (Admissions) hardening — five bugs found by an independent
-- second-pass review, the same rigor already applied to every other
-- module this session. Two are severe: an offer-response endpoint any
-- signed-in user (of any role) could call with no authorization check
-- at all, and a seat-availability formula that stopped holding a seat
-- the moment a family accepted an offer — before an enrolment row ever
-- existed — letting a second offer double-book the same seat.
--
-- Not fixed here, deliberately: admission_offer.admission_fee_amount is
-- `numeric`, not this codebase's bigint-paisa convention — a real gap,
-- but LOW severity (the column is currently write-only/display-only,
-- never read by any ledger-posting code, so there's no double-post or
-- unit-mismatch exposure today) and a column-type change is its own
-- scoped piece of work, not a drive-by alongside four unrelated
-- security/logic fixes.

-- ── 1. fn_respond_to_offer() had no role check at all ───────────────────
--
-- Every other admissions function in this file checks app.auth_role().
-- This one didn't — any authenticated user, of ANY role (librarian,
-- transport_manager, subject_teacher, whichever), could call it and
-- accept or decline any offer in their tenant, and the UI
-- (application-list.tsx) renders the Accept/Decline controls with no
-- role gate either, so this was reachable through the shipped screen,
-- not just a direct RPC call. Scoped to the same admissions roles that
-- can issue an offer in the first place — there is no guardian/parent
-- portal session today that would need a different, ownership-scoped
-- path; when that portal exists, it needs its own explicit RPC, not a
-- wide-open one.

create or replace function public.fn_respond_to_offer(
  p_offer_id uuid, p_response public.offer_status, p_decline_reason public.offer_decline_reason default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_app_id    uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_response not in ('accepted', 'declined') then
    raise exception 'INVALID_RESPONSE' using errcode = '22023';
  end if;
  if p_response = 'declined' and p_decline_reason is null then
    raise exception 'DECLINE_REASON_REQUIRED' using errcode = '23514';
  end if;

  select tenant_id, application_id into v_tenant_id, v_app_id from public.admission_offer where id = p_offer_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.admission_offer
     set status = p_response, responded_at = now(), decline_reason = p_decline_reason
   where id = p_offer_id and status = 'issued';

  if not found then
    raise exception 'OFFER_NOT_RESPONDABLE' using errcode = '55000';
  end if;

  update public.admission_application
     set status = case p_response when 'accepted' then 'accepted'::public.application_status else 'declined'::public.application_status end
   where id = v_app_id;
end;
$$;

-- ── 2. an accepted offer stopped holding its seat ───────────────────────
--
-- fn_available_seats only subtracted offers with status = 'issued'.
-- Accepting an offer (fn_respond_to_offer) flips it to 'accepted' —
-- and nothing else automatically creates the enrolment row that would
-- otherwise hold the seat (enrol_student is a separate, unrelated call
-- with no capacity check of its own tying it back to the offer). Between
-- acceptance and actual enrolment, the seat silently looked free again:
-- issue Offer A for the last seat, Family A accepts, recompute
-- availability -> back to 1 free seat, issue Offer B for the "same" seat,
-- Family B accepts too. Both applications are now accepted for one
-- physical seat. Fixed by counting 'accepted' offers as holding the seat
-- too, alongside still-live 'issued' ones.

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
              and ((o.status = 'issued' and o.expires_at > now()) or o.status = 'accepted')
         )
    from public.class_section cs
   where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.campus_id = p_campus_id
     and cs.tenant_id = app.auth_tenant_id() and cs.is_active;
$$;

-- ── 3. create_followup() never tenant-checked p_assigned_to ─────────────
--
-- app_user.user_id is a single global id with exactly one tenant —
-- fn_reassign_followups() (same file) already validates its target
-- user's tenant before reassigning; create_followup() accepts the
-- identical shape of id and never did. An admissions_officer could
-- assign a follow-up to a foreign tenant's user_id; that user's own
-- my_overdue_followups() call (SECURITY DEFINER, bypasses RLS) would
-- then hand back the leaked row — enquiry id, campus, channel, due
-- date — with no UUID-guessing beyond already knowing one valid user id.

create or replace function public.create_followup(
  p_enquiry_id uuid, p_due_at timestamptz, p_channel public.followup_channel, p_assigned_to uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_enquiry.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_assigned_to is not null and not exists (
    select 1 from public.app_user where user_id = p_assigned_to and tenant_id = app.auth_tenant_id()
  ) then
    raise exception 'ASSIGNEE_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.admission_followup (tenant_id, campus_id, enquiry_id, channel, due_at, assigned_to, created_by)
  values (v_enquiry.tenant_id, v_enquiry.campus_id, p_enquiry_id, p_channel, p_due_at, coalesce(p_assigned_to, auth.uid()), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

-- Defense in depth alongside fix #3 above, matching this codebase's
-- established "close it at both the write path and the read path"
-- pattern (e.g. concession_award's negative-value check plus its table
-- CHECK constraint): even with create_followup() now closed, a stray
-- direct write (or a future caller of this same shape) should not be
-- able to hand a foreign tenant's row back through this function either.
create or replace function public.my_overdue_followups()
returns setof public.admission_followup
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.admission_followup
   where assigned_to = auth.uid() and completed_at is null and due_at < now() and tenant_id = app.auth_tenant_id();
$$;

-- ── 4. fn_submit_application() never checked the enquiry was still open ─
--
-- Calling it twice for the same enquiry (a double-click before the UI's
-- revalidatePath catches up, or a direct retry) created a second,
-- independent application — eligible for its own offer — instead of
-- rejecting the second attempt. The same gap let an application be
-- submitted against an enquiry already closed 'lost', silently reviving
-- a dead lead.

create or replace function public.fn_submit_application(
  p_enquiry_id uuid, p_group_applied public.academic_group default null,
  p_prev_school text default null, p_prev_class_passed text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_ordinal smallint;
  v_group   public.academic_group;
  v_seq     int;
  v_app_no  text;
  v_app_id  uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enquiry.status <> 'open' then
    raise exception 'ENQUIRY_NOT_OPEN' using errcode = '55000';
  end if;

  select ordinal into v_ordinal from public.class_level where id = v_enquiry.class_applied_id;

  if v_ordinal between 10 and 13 then
    if p_group_applied is null then
      raise exception 'Group is required for classes 9-12' using errcode = '23514';
    end if;
    v_group := p_group_applied;
  else
    v_group := null;
  end if;

  insert into public.application_no_counter (campus_id, session_id)
  values (v_enquiry.campus_id, v_enquiry.session_id)
  on conflict (campus_id, session_id) do nothing;

  update public.application_no_counter
     set next_seq = next_seq + 1
   where campus_id = v_enquiry.campus_id and session_id = v_enquiry.session_id
  returning next_seq - 1 into v_seq;

  v_app_no := 'APP-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

  insert into public.admission_application (
    tenant_id, campus_id, session_id, enquiry_id, application_no, class_applied_id, group_applied,
    submitted_by, prev_school, prev_class_passed
  ) values (
    app.auth_tenant_id(), v_enquiry.campus_id, v_enquiry.session_id, p_enquiry_id, v_app_no, v_enquiry.class_applied_id, v_group,
    auth.uid(), p_prev_school, p_prev_class_passed
  )
  returning id into v_app_id;

  update public.admission_enquiry set status = 'converted' where id = p_enquiry_id;

  return v_app_id;
end;
$$;

-- ── 5. fn_close_enquiry() could force an already-converted enquiry back
--    to 'lost' ──────────────────────────────────────────────────────────
--
-- Nothing stopped closing an enquiry as 'lost' after it had already
-- converted to an application (possibly one already offered or
-- accepted) — corrupting any funnel/"lost enquiries" report with a
-- family shown as lost while actually mid-pipeline or already enrolling.

create or replace function public.fn_close_enquiry(p_enquiry_id uuid, p_status public.enquiry_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_open    text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status <> 'lost' then
    raise exception 'UNSUPPORTED_STATUS' using errcode = '22023', detail = 'only the lost transition is handled here — converted happens via fn_submit_application';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enquiry.status <> 'open' then
    raise exception 'ENQUIRY_NOT_OPEN' using errcode = '55000';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_enquiry.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select string_agg(f.channel::text || ' due ' || f.due_at::text, ', ') into v_open
    from public.admission_followup f
   where f.enquiry_id = p_enquiry_id and f.completed_at is null;
  if v_open is not null then
    raise exception 'OPEN_FOLLOWUPS_EXIST' using errcode = '55000', detail = v_open;
  end if;

  update public.admission_enquiry set status = p_status where id = p_enquiry_id;
end;
$$;
