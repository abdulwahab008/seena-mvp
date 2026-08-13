-- FR-G11 fix: approving a correction for a date that was NEVER marked
-- must create the attendance_day row, not raise ATTENDANCE_DAY_NOT_FOUND.
--
-- ── the bug ─────────────────────────────────────────────────────────
--
-- FR-G11's premise was amending an EXISTING mark, so
-- approve_attendance_correction() raised ATTENDANCE_DAY_NOT_FOUND when no
-- attendance_day row existed for the (enrolment, date) being corrected.
-- FR-G10's request side never shared that premise —
-- request_attendance_correction() reads the day row with a plain SELECT
-- and stores a NULL old_status when there isn't one, so a request against
-- an unmarked date has always been legal to file.
--
-- FR-G05 (20260731850000) then made that combination routine rather than
-- theoretical. When a queued offline register is replayed for a date that
-- got locked between capture and sync, rpc_bulk_mark_attendance() cannot
-- raise — raising would roll back the very correction requests that stop
-- the submission being dropped — so it routes every disagreeing mark into
-- request_attendance_correction(). A section that was never marked at all
-- before the lock therefore produces a queue of correction requests a
-- Principal can see but can never approve: every approval errors out.
-- FR-G05's own header flagged this and left it alone because the fix
-- belongs to this function, which FR-G11 had already shipped.
--
-- ── the absent "before" state is NULL, not a stand-in ────────────────
--
-- attendance_audit.old_status is already nullable and, until now, was
-- always populated because the function refused to run without a prior
-- row. NULL is therefore free to mean exactly one thing: there was no
-- prior mark. That is the honest record, and it is the same
-- representation attendance_correction_request.old_status has carried for
-- this case since FR-G11 (the corrections screen already renders it as
-- "unmarked → present"). Nothing is invented to fill the gap — in
-- particular the row is NOT audited as if it had been 'absent' before,
-- which would fabricate a disciplinary fact about a student that nobody
-- ever recorded. Exactly one attendance_audit row is still written per
-- approval, and the append-only trigger still governs it, so AC1/AC2 hold
-- unchanged.
--
-- ── what the created row says about itself ───────────────────────────
--
--   source     = 'correction' (new value, added in 20260731993000). Not
--                'web'/'mobile' — no register was submitted; not
--                'offline_sync' — the row was never in a device queue,
--                and the offline submission that triggered the correction
--                was rejected as 'rejected_locked', never applied. The
--                honest answer is that an approved correction created it.
--   corrected  = true, matching the UPDATE path: this row's status came
--                from a correction, not from marking.
--   marked_by  = the REQUESTER, not the approver. marked_by answers "who
--                asserts this student was present/absent"; in the FR-G05
--                scenario that is the class teacher who tapped it on the
--                device. Who authorised it into the record is a separate
--                fact and already lives in attendance_audit.approved_by,
--                which this function still sets to auth.uid().
--   marked_at  = clock_timestamp(), the moment the mark entered the
--                record. FR-G05 redefined marked_at as capture time, and
--                the real device capture time is not recoverable here —
--                it survives only as prose inside the request's reason
--                text. Parsing an English sentence back into a timestamp
--                would be a guess dressed as a fact, so approval time is
--                recorded instead, and it lines up with the audit row's
--                own approved_at.
--   synced_at  = NULL. Nothing synced; that column means "when a device
--                submission reached the server".
--
-- section_id is read from the enrolment, the same row
-- request_attendance_correction() already resolves the requester's
-- class-teacher authorisation against — attendance_correction_request
-- carries campus_id and session_id but not section_id. No enrolment or
-- student status filter is applied: unlike save_attendance_register(),
-- which silently drops departed students from a bulk roster, this is one
-- named decision a Principal made about one named student, and silently
-- doing nothing would be worse than recording it.
--
-- The INSERT is deliberately plain, with no ON CONFLICT clause. The only
-- way to conflict is a register save landing between this function's
-- SELECT and its INSERT (impossible on a locked date, and impossible from
-- a second correction — uq_pending_correction allows one pending request
-- per enrolment/date), and if that ever happens the right outcome is a
-- rolled-back transaction with the request left pending, not an immutable
-- audit row asserting a "before" state that had stopped being true.
--
-- Everything else is byte-identical to the 20260731530000 version, which
-- is the latest definition of this function.

create or replace function public.approve_attendance_correction(p_correction_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_req        public.attendance_correction_request%rowtype;
  v_day        public.attendance_day%rowtype;
  v_marked     boolean;
  v_section_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_req from public.attendance_correction_request where id = p_correction_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CORRECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'CORRECTION_NOT_PENDING' using errcode = '55000';
  end if;

  -- v_day is all-NULL when there is no row, so v_day.status below is the
  -- genuine absent prior state rather than a placeholder.
  select * into v_day from public.attendance_day where enrolment_id = v_req.enrolment_id and attendance_date = v_req.attendance_date;
  v_marked := found;

  if v_marked then
    update public.attendance_day
       set status = v_req.new_status, corrected = true
     where enrolment_id = v_req.enrolment_id and attendance_date = v_req.attendance_date;
  else
    select section_id into v_section_id from public.enrolment where id = v_req.enrolment_id;

    insert into public.attendance_day (
      tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status,
      marked_by, marked_at, source, synced_at, corrected
    ) values (
      v_tenant_id, v_req.campus_id, v_req.session_id, v_section_id, v_req.enrolment_id, v_req.attendance_date, v_req.new_status,
      v_req.requested_by, clock_timestamp(), 'correction', null, true
    );
  end if;

  insert into public.attendance_audit (
    tenant_id, campus_id, session_id, enrolment_id, attendance_date, old_status, new_status, reason,
    requested_by, approved_by, source_correction_id
  ) values (
    v_tenant_id, v_req.campus_id, v_req.session_id, v_req.enrolment_id, v_req.attendance_date, v_day.status, v_req.new_status, v_req.reason,
    v_req.requested_by, auth.uid(), v_req.id
  );

  update public.attendance_correction_request
     set status = 'approved', decided_by = auth.uid(), decided_at = clock_timestamp(), decision_note = p_note
   where id = p_correction_id;

  -- AC4: flags the enclosing month's summary stale so a recompute picks
  -- this correction up. A no-op if that month hasn't been computed yet.
  update public.attendance_month_summary
     set stale = true
   where enrolment_id = v_req.enrolment_id
     and year = extract(year from v_req.attendance_date)::smallint
     and month = extract(month from v_req.attendance_date)::smallint;
end;
$$;

revoke execute on function public.approve_attendance_correction(uuid, text) from public, anon;
grant execute on function public.approve_attendance_correction(uuid, text) to authenticated;
