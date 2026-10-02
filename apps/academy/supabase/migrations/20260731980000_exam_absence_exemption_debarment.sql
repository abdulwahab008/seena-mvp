-- FR-I11: absent, exempt and debarred handling.
--
-- "As an Exam Controller, I want absence and exemption recorded per paper
-- with a reason, so that percentages and pass/fail decisions treat a missing
-- student correctly."
--
-- Builds on FR-I12 (20260731970000), which deliberately left the room for
-- this: mark_entry.marks_obtained is NOT NULL and carries no sentinel, so a
-- candidate who did not sit a paper has no mark row at all rather than a
-- null, a zero or a -1 that a later computation could mistake for a score.
-- This migration is what fills that room.
--
-- ── The distinction, and why it is not a status column on mark_entry ───
--
-- Exempt shrinks the denominator; Absent does not. That one sentence is,
-- per this FR's own Notes, the largest source of wrong percentages in
-- Pakistani SIS products, and it is a statement about a PAPER, not about a
-- mark: a candidate exempt from Islamiat has no theory mark, no practical
-- mark and no internal mark, and the exemption is one fact about them and
-- that paper, not one fact per component.
--
-- So it lives in its own table, keyed exactly where the FR says —
-- uq_exam_attendance (exam_subject_id, enrolment_id) — and mark_entry gains
-- no status column, no nullable marks and no magic values. The two tables
-- cannot disagree because trg_block_marks_when_not_present refuses a mark
-- for a candidate whose status for that paper is not Present, and
-- set_exam_attendance() refuses to mark someone absent whose marks are
-- already in.
--
-- Silence means Present. There is no row per candidate per paper for the
-- ordinary case, the same exceptions-only shape rpc_bulk_mark_attendance()
-- (FR-G03) already uses for the daily register: writing forty 'present' rows
-- to record that nothing happened is a cost with no reader.
--
-- ── What FR-J02 consumes, and why it cannot get this wrong ────────────
--
-- The whole point of this FR is that the next one computes correctly, so the
-- contract is explicit rather than left as "join these four tables and
-- remember the rule". public.v_exam_result_input is one row per (paper,
-- candidate) carrying four columns FR-J02 reads and no interpretation left
-- to the caller:
--
--   obtained_marks     numeric NOT NULL — 0 for absent, exempt and debarred
--   denominator_marks  integer NOT NULL — 0 for EXEMPT (AC2: the denominator
--                                          shrinks), the paper's full maximum
--                                          for absent and debarred (AC3)
--   blocks_result      boolean          — true for debarred, and a result
--                                          engine that ignores it publishes a
--                                          result it was told not to
--   report_symbol      text             — 'AB' (AC3), 'EX', 'DEB', else null
--
-- Both numeric columns are NOT NULL and are already the number to sum. There
-- is nothing in that view a computation can treat as a mark that is not one:
-- the status enum never reaches an arithmetic column, and the arithmetic
-- columns never carry a status. A percentage is
-- sum(obtained_marks) / nullif(sum(denominator_marks), 0), and the exempt
-- subject has already removed itself from the bottom of that fraction.
--
-- ── AC1's message ─────────────────────────────────────────────────────
--
-- "candidate is marked Absent for this paper", with the status word from the
-- row rather than hardcoded, so Exempt and Debarred read correctly too:
-- format('candidate is marked %s for this paper', initcap(status)). Raised
-- with 23514, which PostgREST maps to HTTP 400 with the message intact —
-- not SQLSTATE class 55, which it replaces with "Something went wrong"
-- (verified against this stack in FR-I01's migration).
--
-- ── AC4: what "the break-glass path" is in this schema ────────────────
--
-- There is no break-glass overlay here — FR-A08's own migration recorded
-- skipping one, and the custom_access_token_hook's support-impersonation
-- path in the foundation migration is about signing in, not about editing a
-- published result. What this schema actually has, and what FR-I01 and
-- FR-I02 both already point users at, is the result-recompute request. So
-- the refusal names that rather than inventing a second escape hatch that
-- nothing implements:
--
--   'candidate exam status is locked by approved marks — the break-glass
--    path is a result-recompute request'
--
-- errcode 42501, the same code and the same shape as FR-I01's weightage
-- freeze and FR-I02's setup freeze, and enforced by a TRIGGER so
-- service_role and the table owner are held to it too — a policy binds only
-- the roles it names.
--
-- The freeze bites on either of two conditions: a mark for that candidate
-- and paper is already 'approved' or 'locked', or FR-I01's
-- app.fn_exam_term_weight_frozen() reports the whole term frozen. The second
-- is the seam FR-I16 will drive; the first is real the moment mark statuses
-- start moving.
--
-- ── Who may record what ───────────────────────────────────────────────
--
-- The FR's Actors are Teacher, Exam Controller and System, and the two are
-- not interchangeable:
--
--   * a teacher who teaches the class-subject (app.fn_can_enter_marks, the
--     FR-I12 predicate, reused rather than restated) may record 'present'
--     and 'absent' — they are the person in the hall, and an empty chair is
--     an observation;
--   * 'exempt' and 'debarred' are the exam office's (super_admin, owner,
--     principal, vice_principal, exam_controller). A religious exemption is
--     an entitlement decision and a debarment is a disciplinary or fee one;
--     neither is something the invigilator concludes.
--
-- ── The FR's suggested objects, and the two deviations ────────────────
--
-- exam_attendance, both enums, trg_block_marks_when_not_present,
-- uq_exam_attendance and exam_attendance_teacher_own_section are built as
-- named. exam_attendance_controller_write is NOT: RLS with no INSERT/UPDATE
-- policy denies both by default and set_exam_attendance() is the only
-- writer, so adding one would split authorization across two mechanisms for
-- no gain — the same call FR-I01 made about exam_term_write_controller.

-- ═══════════════════════════════════════════════════════════════════════
-- Schema
-- ═══════════════════════════════════════════════════════════════════════

create type public.exam_attendance_status as enum ('present', 'absent', 'exempt', 'debarred');

create type public.exam_absence_reason as enum (
  'medical', 'unauthorised', 'fee_default', 'religious_exemption', 'board_exemption', 'disciplinary'
);

create table public.exam_attendance (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  exam_subject_id uuid not null references public.exam_subject(id) on delete cascade,
  enrolment_id    uuid not null references public.enrolment(id) on delete cascade,
  status          public.exam_attendance_status not null,
  reason          public.exam_absence_reason,
  note            text,
  recorded_by     uuid references public.app_user(user_id),
  recorded_at     timestamptz not null default now(),
  -- The requirement's "mandatory reason code", both ways: a non-present
  -- status must carry one, and 'present' must not — "present, medical" is
  -- not a thing, and allowing it would put a reason on the rows the result
  -- engine reads as ordinary.
  constraint chk_exam_attendance_reason check ((status = 'present') = (reason is null))
);

create unique index uq_exam_attendance on public.exam_attendance (exam_subject_id, enrolment_id);
create index idx_exam_attendance_enrolment on public.exam_attendance (enrolment_id);
-- The debarment lookup FR-J02 makes per candidate per term.
create index idx_exam_attendance_blocking on public.exam_attendance (exam_subject_id)
  where status = 'debarred';

create trigger exam_attendance_audit after insert or update or delete on public.exam_attendance
  for each row execute function app.tg_audit_row();

comment on table public.exam_attendance is
  'FR-I11: per-candidate, per-paper Present/Absent/Exempt/Debarred with a mandatory reason. No row means Present. Never a mark — see v_exam_result_input for what a computation reads.';
comment on column public.exam_attendance.status is
  'Exempt shrinks the result denominator; Absent scores 0 against the full maximum; Debarred blocks the result entirely.';

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: no mark for a candidate who did not sit the paper
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_marks_when_not_present()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.exam_attendance_status;
begin
  select status into v_status
    from public.exam_attendance
   where exam_subject_id = new.exam_subject_id and enrolment_id = new.enrolment_id;

  -- No row is Present: absence is the exception that gets recorded.
  if v_status is null or v_status = 'present' then
    return new;
  end if;

  -- AC1's sentence, with the status from the row so Exempt and Debarred read
  -- correctly too.
  raise exception '%', format('candidate is marked %s for this paper', initcap(v_status::text))
    using errcode = '23514',
          detail = format('enrolment %s, component %s', new.enrolment_id, new.component_code),
          hint = 'Change the candidate''s exam status first if they did in fact sit this paper.';
end;
$$;

-- Postgres fires BEFORE row triggers in name order, so this one runs ahead of
-- trg_mark_range_check: a mark for an absent candidate is refused for the
-- absence whatever its value, which is the complaint that actually matters —
-- "max 65" would send the teacher off to correct a number that was never
-- going to be stored.
create trigger trg_block_marks_when_not_present
  before insert or update on public.mark_entry
  for each row execute function app.tg_block_marks_when_not_present();

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the freeze
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_exam_attendance_frozen(
  p_exam_subject_id uuid,
  p_enrolment_id    uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.exam_subject es
     where es.id = p_exam_subject_id
       and app.fn_exam_term_weight_frozen(es.exam_term_id)
  )
  or exists (
    select 1
      from public.mark_entry m
     where m.exam_subject_id = p_exam_subject_id
       and m.enrolment_id = p_enrolment_id
       and m.status in ('approved', 'locked')
  );
$$;

create or replace function app.tg_exam_attendance_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if app.fn_exam_attendance_frozen(old.exam_subject_id, old.enrolment_id) then
    raise exception 'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request'
      using errcode = '42501',
            detail = format('exam_subject %s, enrolment %s (currently %s)',
                            old.exam_subject_id, old.enrolment_id, old.status),
            hint = 'Correcting a status a published result was computed from is a result correction, not an edit.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger trg_exam_attendance_frozen
  before update or delete on public.exam_attendance
  for each row execute function app.tg_exam_attendance_frozen();

-- ═══════════════════════════════════════════════════════════════════════
-- Writer
-- ═══════════════════════════════════════════════════════════════════════

-- The only writer. See the header for why a teacher may record present and
-- absent but not exempt or debarred.
create or replace function public.set_exam_attendance(
  p_exam_subject_id uuid,
  p_enrolment_id    uuid,
  p_status          public.exam_attendance_status,
  p_reason          public.exam_absence_reason default null,
  p_note            text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_es        record;
  v_section   uuid;
  v_id        uuid;
begin
  select es.id, es.tenant_id, es.campus_id, es.exam_term_id
    into v_es
    from public.exam_subject es
   where es.id = p_exam_subject_id;
  if v_es.id is null then
    raise exception 'EXAM_SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_id is not null and v_es.tenant_id <> v_tenant_id then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- SECURITY DEFINER bypasses RLS, so the soft-delete filter is explicit.
  select e.section_id into v_section
    from public.enrolment e
   where e.id = p_enrolment_id and e.deleted_at is null;
  if v_section is null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not app.fn_can_enter_marks(p_exam_subject_id, v_section) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status in ('exempt', 'debarred')
     and app.auth_tenant_id() is not null
     and app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    raise exception 'EXAM_STATUS_OFFICE_ONLY' using errcode = '42501',
      detail = 'An exemption is an entitlement decision and a debarment a disciplinary one — both are the exam office''s.';
  end if;

  -- The requirement's mandatory reason code, raised ahead of
  -- chk_exam_attendance_reason so the caller gets a named error rather than
  -- a constraint violation.
  if p_status <> 'present' and p_reason is null then
    raise exception 'ABSENCE_REASON_REQUIRED' using errcode = '23514',
      detail = 'Absent, exempt and debarred each need a reason code.';
  end if;
  if p_status = 'present' and p_reason is not null then
    raise exception 'REASON_NOT_APPLICABLE' using errcode = '23514',
      detail = 'A candidate who sat the paper has no absence reason.';
  end if;

  -- AC4, raised ahead of trg_exam_attendance_frozen so the caller sees the
  -- sentence rather than a trigger-wrapped one — and ahead of the
  -- already-entered check below, because a candidate whose marks are
  -- APPROVED trips both and the lock is the more useful answer: it says what
  -- to do next, where "clear the marks first" would send the user at a
  -- refusal they cannot get past either.
  if app.fn_exam_attendance_frozen(p_exam_subject_id, p_enrolment_id) then
    raise exception 'candidate exam status is locked by approved marks — the break-glass path is a result-recompute request'
      using errcode = '42501';
  end if;

  -- Marks already on record would contradict the new status, and silently
  -- deleting a teacher's work to resolve that is worse than refusing. The
  -- marks come out first, deliberately by hand.
  if p_status <> 'present' and exists (
    select 1 from public.mark_entry
     where exam_subject_id = p_exam_subject_id and enrolment_id = p_enrolment_id
  ) then
    raise exception 'MARKS_ALREADY_ENTERED' using errcode = '23514',
      detail = 'Clear this candidate''s marks for the paper before recording them as not present.';
  end if;

  insert into public.exam_attendance (
    tenant_id, campus_id, exam_subject_id, enrolment_id, status, reason, note, recorded_by
  ) values (
    v_es.tenant_id, v_es.campus_id, p_exam_subject_id, p_enrolment_id, p_status, p_reason, p_note,
    (select auth.uid())
  )
  on conflict (exam_subject_id, enrolment_id) do update
    set status      = excluded.status,
        reason      = excluded.reason,
        note        = excluded.note,
        recorded_by = excluded.recorded_by,
        recorded_at = now()
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_exam_attendance(
  uuid, uuid, public.exam_attendance_status, public.exam_absence_reason, text
) from public, anon;
grant execute on function public.set_exam_attendance(
  uuid, uuid, public.exam_attendance_status, public.exam_absence_reason, text
) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2 / AC3: what FR-J02 reads
-- ═══════════════════════════════════════════════════════════════════════

-- One row per (paper, candidate). See the header: obtained_marks and
-- denominator_marks are always numbers, blocks_result is always a boolean,
-- and the status enum never leaks into either.
create view public.v_exam_result_input
with (security_invoker = true) as
select
  es.id                                             as exam_subject_id,
  es.tenant_id,
  es.campus_id,
  es.exam_term_id,
  cs.subject_id,
  cs.class_level_id,
  cs.stream_id,
  sec.id                                            as section_id,
  e.id                                              as enrolment_id,
  e.student_id,
  coalesce(a.status, 'present')                     as attendance_status,
  a.reason                                          as absence_reason,
  -- AC3: absent contributes 0 obtained. AC2: so does exempt. Only a
  -- candidate who sat the paper contributes what they scored.
  case when coalesce(a.status, 'present') = 'present'
       then coalesce(mk.obtained, 0)
       else 0
  end::numeric                                      as obtained_marks,
  -- AC2: EXEMPT shrinks the denominator to nothing. AC3: absent does not —
  -- it scores zero against the paper's full maximum. Debarred keeps the full
  -- maximum too; whether the result exists at all is blocks_result's answer,
  -- not the denominator's.
  case when coalesce(a.status, 'present') = 'exempt'
       then 0
       else coalesce(comp.total_max_marks, 0)
  end::integer                                      as denominator_marks,
  coalesce(comp.total_max_marks, 0)                 as paper_max_marks,
  coalesce(a.status, 'present') = 'debarred'        as blocks_result,
  -- AC3: the report card prints 'AB'.
  case coalesce(a.status, 'present')
    when 'absent'   then 'AB'
    when 'exempt'   then 'EX'
    when 'debarred' then 'DEB'
    else null
  end                                               as report_symbol
from public.exam_subject es
join public.class_subject cs on cs.id = es.class_subject_id
-- The same class-level resolution FR-I02's v_exam_section_subject_setup
-- uses: a stream-less curriculum row applies to every section of the class,
-- a stream-specific one only to the sections in that stream.
join public.class_section sec
  on sec.tenant_id = cs.tenant_id
 and sec.campus_id = cs.campus_id
 and sec.session_id = cs.session_id
 and sec.class_level_id = cs.class_level_id
 and (cs.stream_id is null or cs.stream_id = sec.stream_id)
 and sec.is_active
join public.enrolment e
  on e.section_id = sec.id
 and e.status = 'active'
 and e.deleted_at is null
left join public.exam_attendance a
  on a.exam_subject_id = es.id and a.enrolment_id = e.id
left join lateral (
  select sum(c.max_marks)::int as total_max_marks
    from public.exam_subject_component c
   where c.exam_subject_id = es.id
) comp on true
left join lateral (
  select sum(m.marks_obtained) as obtained
    from public.mark_entry m
   where m.exam_subject_id = es.id and m.enrolment_id = e.id
) mk on true;

revoke all on public.v_exam_result_input from public, anon;
grant select on public.v_exam_result_input to authenticated;

comment on view public.v_exam_result_input is
  'FR-I11: the typed contract FR-J02 computes from. obtained_marks and denominator_marks are always numbers; exempt zeroes the denominator, absent does not, debarred sets blocks_result.';

-- "Debarred blocks the result entirely" — asked once per candidate per term
-- rather than by every caller re-deriving it from the view.
--
-- SECURITY DEFINER, so the tenant/campus scope is written out: a definer
-- function owned by postgres bypasses RLS (FR-K24's finding).
create or replace function public.fn_exam_result_blocked(
  p_exam_term_id uuid,
  p_enrolment_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  select t.tenant_id, t.campus_id into v_tenant_id, v_campus_id
    from public.exam_term t where t.id = p_exam_term_id;
  if v_tenant_id is null then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;

  if app.auth_tenant_id() is not null then
    if v_tenant_id <> app.auth_tenant_id() then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (v_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  return exists (
    select 1
      from public.exam_attendance a
      join public.exam_subject es on es.id = a.exam_subject_id
     where es.exam_term_id = p_exam_term_id
       and a.enrolment_id = p_enrolment_id
       and a.status = 'debarred'
  );
end;
$$;

revoke execute on function public.fn_exam_result_blocked(uuid, uuid) from public, anon;
grant execute on function public.fn_exam_result_blocked(uuid, uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- FR-I12's sheet learns about the status column
-- ═══════════════════════════════════════════════════════════════════════

-- Same three-argument signature, so this is a genuine replacement rather
-- than a second overload — the defaulted-argument ambiguity FR-G05's
-- migration had to drop-and-recreate around does not arise here.
create or replace function public.fn_mark_entry_sheet(
  p_exam_term_id uuid,
  p_section_id   uuid,
  p_subject_id   uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_readiness jsonb;
  v_es_id     uuid;
  v_campus_id uuid;
  v_students  jsonb;
begin
  v_readiness := public.fn_exam_entry_readiness(p_exam_term_id, p_section_id, p_subject_id);
  v_es_id := nullif(v_readiness ->> 'exam_subject_id', '')::uuid;

  select campus_id into v_campus_id from public.class_section where id = p_section_id;

  select coalesce(
           jsonb_agg(
             jsonb_build_object(
               'enrolment_id',      s.enrolment_id,
               'roll_no',           s.roll_no,
               'student_name',      s.student_name,
               'gr_number',         s.gr_number,
               'marks',             s.marks,
               'status',            s.mark_status,
               -- FR-I11. Always present, always one of the four values, so a
               -- grid never has to infer "sat the paper" from an empty cell.
               'attendance_status', s.attendance_status,
               'absence_reason',    s.absence_reason,
               'report_symbol',     s.report_symbol
             )
             order by s.roll_no nulls last, s.student_name
           ),
           '[]'::jsonb
         )
    into v_students
    from (
      select e.id                as enrolment_id,
             e.roll_no,
             st.name_en          as student_name,
             st.gr_number,
             coalesce(
               (select jsonb_object_agg(m.component_code, m.marks_obtained)
                  from public.mark_entry m
                 where m.exam_subject_id = v_es_id and m.enrolment_id = e.id),
               '{}'::jsonb
             )                   as marks,
             (select max(m.status::text)
                from public.mark_entry m
               where m.exam_subject_id = v_es_id and m.enrolment_id = e.id) as mark_status,
             coalesce(a.status::text, 'present')                            as attendance_status,
             a.reason::text                                                 as absence_reason,
             case a.status
               when 'absent'   then 'AB'
               when 'exempt'   then 'EX'
               when 'debarred' then 'DEB'
               else null
             end                                                            as report_symbol
        from public.enrolment e
        join public.student st on st.id = e.student_id
        left join public.exam_attendance a
          on a.exam_subject_id = v_es_id and a.enrolment_id = e.id
       where e.section_id = p_section_id
         and e.status = 'active'
         and e.deleted_at is null
         and st.deleted_at is null
    ) s;

  return v_readiness
    || jsonb_build_object(
         'can_enter',      app.fn_can_enter_marks(v_es_id, p_section_id),
         'mark_precision', app.fn_mark_precision(v_campus_id),
         -- Only the exam office may record an exemption or a debarment.
         'can_exempt',     app.auth_tenant_id() is null
                             or app.auth_role() in ('super_admin', 'owner', 'principal',
                                                    'vice_principal', 'exam_controller'),
         'students',       v_students
       );
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.exam_attendance enable row level security;

-- The FR's exam_attendance_teacher_own_section, the same shape as FR-I12's
-- marks_teacher_own_section and reusing the same predicate rather than
-- restating it. Writes get no policy — see the header.
create policy exam_attendance_teacher_own_section on public.exam_attendance
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or (
        campus_id = any(app.auth_campus_ids())
        and (
          app.auth_role() in ('principal', 'vice_principal', 'exam_controller')
          or app.fn_can_read_mark(exam_subject_id, enrolment_id)
        )
      )
    )
  );
