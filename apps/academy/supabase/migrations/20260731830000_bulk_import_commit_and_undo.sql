-- FR-C15: commit a bulk student import atomically, with an error report.
--
-- "As a Super Admin onboarding a school, I want the validated rows
-- committed all-or-nothing with a downloadable failure report, so that a
-- mid-file error never leaves the school half-migrated."
--
-- This is the write half of FR-C14's dry run. C14 deliberately left
-- public.student, public.gr_sequence and public.gr_ledger untouched and
-- shaped its schema for this migration; everything below slots into that
-- shape. The one place this departs from what C14's header predicted is
-- called out under "what gets committed" below.
--
-- ── what gets committed ────────────────────────────────────────────────
-- C14's header guessed C15 would refuse a batch whose error_rows > 0. It
-- does not, and cannot: the FR's own AC1 commits 4,882 students out of the
-- 5,000-row file C14's AC describes as "4,882 ready and 118 blocked", and
-- the user story asks for the commit AND a failure report in the same
-- breath. Forcing a school to fix 118 rows before a single one of the
-- other 4,882 can land is the opposite of what the story wants. So:
--   * the importable set is exactly C14's ok_rows (severity 'ok' or
--     'warning'), and "all-or-nothing" is a statement about THAT set;
--   * the blocked rows were never candidates - they become the failure
--     report (bucket `import-errors`, one CSV per batch), which the school
--     fixes and re-uploads as a second, smaller file.
--
-- ── AC4: roll everything back, but still record the failure ────────────
-- "the ENTIRE batch rolls back" and "the batch is marked failed with the
-- offending row and message" are contradictory for a single transaction:
-- a plain `raise` would discard the marking along with the data. The
-- resolution is plpgsql's own subtransaction semantics - a BEGIN block
-- with an EXCEPTION clause is a savepoint, so:
--   1. every write to student/gr_sequence/gr_ledger/enrolment happens
--      inside that block. An error rolls the block back to the savepoint:
--      no student, no ledger row, no advanced GR counter, nothing;
--   2. the handler runs in the OUTER transaction, which is still live, and
--      writes import_batch.failed_at / failed_row_no / failed_message
--      there. That write commits;
--   3. commit_import_batch RETURNS ok=false rather than re-raising -
--      re-raising would abort the outer transaction and take the marking
--      with it, which is the exact trap this AC is describing.
-- The offending row number survives because plpgsql variables are memory,
-- not transactional state: v_row_no is assigned at the top of each loop
-- iteration and still holds the failing row's number after the rollback.
--
-- There is no 'failed' value in import_batch_status, on purpose - C14
-- shipped that enum with 'committed' and 'undone' precisely so C15 would
-- need no ALTER TYPE ... ADD VALUE (which cannot share a migration file
-- with any statement that uses the new value; see
-- 20260731800000_student_status_enum_extend_passed_out.sql, which exists
-- only because of that rule). A failed commit therefore leaves status at
-- 'validated' - the batch IS still validated, and is retryable the moment
-- the cause is fixed - and records the failure in its own columns.
-- v_import_batch.commit_state resolves the two into the single word the
-- UI and the ACs talk about ('failed').
--
-- ── create_student() / enrol_student() reuse ───────────────────────────
-- create_student() is not usable here at all: it has no parameter for a
-- school-supplied GR number, and AC3 is entirely about school-supplied GR
-- numbers. It also allocates one number per call via
-- app.fn_allocate_gr_number(), i.e. one SELECT ... FOR UPDATE on the same
-- single gr_sequence row per student - the per-row allocation this FR
-- explicitly replaces with one UPDATE for the whole block.
-- fn_enrol_from_offer() (FR-B17) already set the precedent of inlining the
-- same insert logic when create_student()'s shape does not fit a caller.
-- Every guard create_student() applies is still applied: the B-Form
-- format/duplicate and GR-in-use checks ran at validation time (C14), and
-- GR-in-use is re-checked per row here because the register can move
-- between validating and committing.
--
-- enrol_student() IS reused in spirit but not by call: its per-call work
-- (re-reading the section, re-reading the student, re-checking the role)
-- is pure overhead 4,882 times over, and the section it would be given
-- still has to be chosen here. The two rows it writes - enrolment and
-- section_membership_history - are written identically below, and the
-- capacity invariant it relies on is enforced by the same
-- trg_enrolment_capacity_check trigger, which fires on these inserts too.
-- The inserts stay row-by-row rather than one set-based INSERT..SELECT for
-- two reasons: a single multi-row INSERT cannot tell you WHICH row broke
-- (AC4 needs the row number), and the capacity trigger's own
-- `select count(*) from enrolment` cannot see rows inserted earlier by the
-- same command, so a bulk insert would silently defeat it.
--
-- ── GR block allocation (AC3) ──────────────────────────────────────────
-- One SELECT ... FOR UPDATE and one UPDATE on gr_sequence for the whole
-- batch, not one per row. The new next_value is
--     greatest(next_value, max_supplied_ordinal + 1) + rows_needing_a_number
-- so that (a) a file supplying historical numbers up to 8,450 leaves the
-- counter at 8,451 even when it needs no allocation at all, and (b) any
-- auto-allocated block starts ABOVE every number the school supplied, so
-- an allocated number can never collide with a supplied one later in the
-- same file. app.fn_gr_ordinal() is what reads "8450" or "MAIN-008450" as
-- 8450; a number in neither shape (a free-form paper reference like
-- "REG/7-B") is written to the register verbatim and simply does not move
-- the counter, which is the only honest thing to do with it.
--
-- ── undo (AC5) ─────────────────────────────────────────────────────────
-- Two independent gates, both required: inside undo_deadline (committed_at
-- + 24 hours) AND nothing depending on the imported students. The
-- dependency list is fee_challan / fee_ledger / fee_payment /
-- concession_award / attendance_day, plus a foreign_key_violation
-- catch-all for anything not enumerated (the same belt-and-braces
-- purge_soft_deleted_records uses - there is no marks/result table in this
-- schema yet, and the catch-all is what makes one block the undo the day
-- it lands). fee_plan is deliberately NOT a blocker: it is created as a
-- side effect of the enrolment insert itself by enrolment_ai_build_fee_plan
-- whenever the campus has a published fee structure, so treating it as
-- evidence of school activity would make undo impossible for exactly the
-- schools most likely to need it. It carries no money and cascades with
-- the enrolment.
--
-- The GR counter is rewound only if it is still exactly where the commit
-- left it. gr_sequence's own header calls the register gapless; handing
-- the numbers back is right when nobody else has taken one since, and
-- unsafe the moment somebody has.
--
-- ── retention ──────────────────────────────────────────────────────────
-- purge_import_staging() is the real, un-scheduled cleanup function, same
-- convention as purge_soft_deleted_records / compute_month_attendance /
-- run_unmarked_attendance_check: a service_role-grantable function a
-- pg_cron job WOULD call, not actually scheduled (no pg_cron locally).

-- ── schema ──────────────────────────────────────────────────────────────

alter table public.import_batch add column committed_at          timestamptz;
alter table public.import_batch add column committed_by          uuid references public.app_user(user_id);
alter table public.import_batch add column committed_rows        int not null default 0;
alter table public.import_batch add column undo_deadline         timestamptz;
alter table public.import_batch add column undone_at             timestamptz;
alter table public.import_batch add column undone_by             uuid references public.app_user(user_id);
alter table public.import_batch add column failed_at             timestamptz;
alter table public.import_batch add column failed_row_no         int;
alter table public.import_batch add column failed_message        text;
alter table public.import_batch add column error_report_path     text;
alter table public.import_batch add column gr_next_value_before  bigint;
alter table public.import_batch add column gr_next_value_after   bigint;

-- What the commit created, so undo knows exactly what to take back.
alter table public.import_row add column student_id   uuid references public.student(id);
alter table public.import_row add column enrolment_id uuid references public.enrolment(id);

create index idx_import_row_student on public.import_row (student_id) where student_id is not null;

-- The single word the UI and the ACs use, resolved from the enum plus the
-- failure columns (see the header on why 'failed' is not an enum value).
create view public.v_import_batch
with (security_invoker = true) as
select
  b.*,
  case
    when b.undone_at is not null    then 'undone'
    when b.committed_at is not null then 'committed'
    when b.failed_at is not null    then 'failed'
    else b.status::text
  end as commit_state,
  (b.status = 'committed' and b.undone_at is null and b.undo_deadline > now()) as can_undo
from public.import_batch b;

-- ── app.fn_gr_ordinal ───────────────────────────────────────────────────
-- The integer a GR number represents, or null when it does not represent
-- one. Bounded to 18 digits so a junk value cannot overflow bigint and
-- abort the whole commit with 22003.

create or replace function app.fn_gr_ordinal(p_prefix text, p_gr text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select case
    when p_gr is null then null
    when p_gr ~ '^[0-9]{1,18}$' then p_gr::bigint
    when p_prefix is not null
     and left(p_gr, length(p_prefix) + 1) = p_prefix || '-'
     and substr(p_gr, length(p_prefix) + 2) ~ '^[0-9]{1,18}$'
      then substr(p_gr, length(p_prefix) + 2)::bigint
    else null
  end;
$$;

revoke execute on function app.fn_gr_ordinal(text, text) from public, anon, authenticated;

-- ── commit_import_batch ─────────────────────────────────────────────────
-- Named for C14's own family (create_/stage_/finalise_import_batch) rather
-- than the fn_ prefix used elsewhere in the schema, so the whole import
-- lifecycle reads as one set of verbs.

create or replace function public.commit_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_batch         public.import_batch%rowtype;
  v_row           record;
  v_row_no        int;
  v_sections      jsonb;
  v_section_id    uuid;
  v_prefix        text;
  v_pad_width     int;
  v_before        bigint;
  v_after         bigint;
  v_next          bigint;
  v_max_supplied  bigint;
  v_auto_count    int;
  v_gr            text;
  v_student_id    uuid;
  v_enrolment_id  uuid;
  v_committed     int := 0;
  v_report_path   text;
  v_now           timestamptz := now();
  v_failed        boolean := false;
  v_message       text;
  v_detail        text;
  v_sqlstate      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- FOR UPDATE, not an advisory lock: AC2's "the same batch id submitted
  -- twice" is two transactions racing on this exact row, and the second
  -- one must see the first one's status once it lands.
  select * into v_batch from public.import_batch
   where id = p_batch_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'IMPORT_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_batch.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC2: the second call is rejected outright, before anything is written.
  if v_batch.status = 'committed' then
    raise exception 'IMPORT_BATCH_ALREADY_COMMITTED' using errcode = '55000',
      detail = format('committed_at=%s committed_rows=%s', v_batch.committed_at, v_batch.committed_rows);
  end if;
  if v_batch.status = 'undone' then
    raise exception 'IMPORT_BATCH_UNDONE' using errcode = '55000';
  end if;
  if v_batch.status <> 'validated' then
    raise exception 'IMPORT_BATCH_NOT_VALIDATED' using errcode = '55000';
  end if;
  if v_batch.ok_rows = 0 then
    raise exception 'IMPORT_BATCH_HAS_NO_IMPORTABLE_ROWS' using errcode = '55000';
  end if;

  -- A retry starts from a clean slate; a stale failure marking left next
  -- to a successful commit would be unreadable.
  update public.import_batch
     set failed_at = null, failed_row_no = null, failed_message = null
   where id = p_batch_id;

  begin
    -- Free seats per section, read once. Kept in a jsonb map rather than a
    -- temp table (no cross-call lifetime to manage inside a pooled
    -- connection) and decremented as rows are placed, so the greedy
    -- least-filled rule fn_auto_balance_sections/execute_rollover_batch
    -- already use costs one `group by` for the whole batch instead of one
    -- per student.
    select coalesce(jsonb_agg(jsonb_build_object(
             'section_id',         cs.id,
             'class_level_id',     cs.class_level_id,
             'name',               cs.name,
             'gender_restriction', cs.gender_restriction,
             'seats_free',         cs.capacity - coalesce(cnt.c, 0)
           )), '[]'::jsonb)
      into v_sections
      from public.class_section cs
      left join (
        select section_id, count(*)::int as c
          from public.enrolment
         where status = 'active' and deleted_at is null
         group by section_id
      ) cnt on cnt.section_id = cs.id
     where cs.campus_id = v_batch.campus_id
       and cs.session_id = v_batch.session_id
       and cs.is_active;

    -- ── the whole GR block, in one UPDATE ────────────────────────────────
    select prefix, pad_width, next_value
      into v_prefix, v_pad_width, v_before
      from public.gr_sequence
     where campus_id = v_batch.campus_id
     for update;
    if not found then
      raise exception 'GR_SEQUENCE_NOT_CONFIGURED' using errcode = 'P0002';
    end if;

    select count(*) filter (where nullif(r.normalised ->> 'gr_number', '') is null)::int,
           max(app.fn_gr_ordinal(v_prefix, nullif(r.normalised ->> 'gr_number', '')))
      into v_auto_count, v_max_supplied
      from public.import_row r
     where r.batch_id = p_batch_id and r.severity <> 'error';

    v_next  := greatest(v_before, coalesce(v_max_supplied + 1, 0));
    v_after := v_next + v_auto_count;

    update public.gr_sequence set next_value = v_after where campus_id = v_batch.campus_id;

    -- ── the rows ─────────────────────────────────────────────────────────
    for v_row in
      select r.id, r.row_no, r.normalised
        from public.import_row r
       where r.batch_id = p_batch_id and r.severity <> 'error'
       order by r.row_no
    loop
      v_row_no := v_row.row_no;

      v_gr := nullif(v_row.normalised ->> 'gr_number', '');
      if v_gr is null then
        v_gr  := v_prefix || '-' || lpad(v_next::text, v_pad_width, '0');
        v_next := v_next + 1;
      end if;

      -- Same guard create_student() applies (FR-A15's GR_NUMBER_IN_USE):
      -- the register can gain a student between validating and committing.
      if exists (select 1 from public.student where tenant_id = v_tenant_id and gr_number = v_gr) then
        raise exception 'GR_NUMBER_IN_USE' using errcode = '23505', detail = format('gr_number=%s', v_gr);
      end if;

      insert into public.student (
        tenant_id, campus_id, gr_number, name_en, name_ur, father_name_en, father_name_ur,
        dob, gender, religion, nationality, b_form_no, blood_group
      ) values (
        v_tenant_id, v_batch.campus_id, v_gr,
        v_row.normalised ->> 'name_en',
        nullif(v_row.normalised ->> 'name_ur', ''),
        nullif(v_row.normalised ->> 'father_name_en', ''),
        nullif(v_row.normalised ->> 'father_name_ur', ''),
        (v_row.normalised ->> 'dob')::date,
        (v_row.normalised ->> 'gender')::public.gender,
        nullif(v_row.normalised ->> 'religion', ''),
        coalesce(nullif(v_row.normalised ->> 'nationality', ''), 'PK'),
        nullif(v_row.normalised ->> 'b_form_no', ''),
        nullif(v_row.normalised ->> 'blood_group', '')
      )
      returning id into v_student_id;

      -- AC3: a school-supplied historical number lands in the permanent
      -- register exactly like an allocated one.
      insert into public.gr_ledger (campus_id, gr_number, student_id, allocated_by)
      values (v_batch.campus_id, v_gr, v_student_id, auth.uid());

      select (e.value ->> 'section_id')::uuid
        into v_section_id
        from jsonb_array_elements(v_sections) as e
       where e.value ->> 'class_level_id' = v_row.normalised ->> 'class_level_id'
         and (e.value ->> 'seats_free')::int > 0
         and (e.value ->> 'gender_restriction' is null
              or e.value ->> 'gender_restriction' = v_row.normalised ->> 'gender')
       order by (e.value ->> 'seats_free')::int desc, e.value ->> 'name'
       limit 1;

      if v_section_id is null then
        raise exception 'NO_SECTION_SEAT_FOR_CLASS' using errcode = '23514',
          detail = format('class_level_id=%s', v_row.normalised ->> 'class_level_id');
      end if;

      select jsonb_agg(
               case when (e.value ->> 'section_id')::uuid = v_section_id
                 then jsonb_set(e.value, '{seats_free}', to_jsonb((e.value ->> 'seats_free')::int - 1))
                 else e.value
               end)
        into v_sections
        from jsonb_array_elements(v_sections) as e;

      insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
      values (
        v_tenant_id, v_batch.campus_id, v_batch.session_id, v_student_id,
        (v_row.normalised ->> 'class_level_id')::uuid, v_section_id
      )
      returning id into v_enrolment_id;

      insert into public.section_membership_history (enrolment_id, section_id, from_date, moved_by, reason)
      values (v_enrolment_id, v_section_id, current_date, auth.uid(), 'bulk import');

      update public.import_row
         set student_id = v_student_id, enrolment_id = v_enrolment_id
       where id = v_row.id;

      v_committed := v_committed + 1;
    end loop;

    if v_batch.error_rows > 0 then
      v_report_path := v_tenant_id::text || '/' || p_batch_id::text || '/failures_' || p_batch_id::text || '.csv';
    end if;

    update public.import_batch
       set status               = 'committed',
           dry_run              = false,
           committed_at         = v_now,
           committed_by         = auth.uid(),
           committed_rows       = v_committed,
           undo_deadline        = v_now + interval '24 hours',
           gr_next_value_before = v_before,
           gr_next_value_after  = v_after,
           error_report_path    = v_report_path
     where id = p_batch_id;

  exception
    -- AC4. Reaching here has already rolled the block above back to its
    -- implicit savepoint: no student, no enrolment, no gr_ledger row, and
    -- gr_sequence.next_value is back where it started.
    when others then
      get stacked diagnostics
        v_message  = message_text,
        v_detail   = pg_exception_detail,
        v_sqlstate = returned_sqlstate;
      v_failed := true;
  end;

  if v_failed then
    -- Outside the rolled-back block, in the still-live outer transaction:
    -- this is the write that has to survive, so the function returns
    -- instead of re-raising.
    update public.import_batch
       set failed_at      = clock_timestamp(),
           failed_row_no  = v_row_no,
           failed_message = left(
             v_message || case when coalesce(v_detail, '') = '' then '' else ' (' || v_detail || ')' end,
             500)
     where id = p_batch_id;

    return jsonb_build_object(
      'ok', false,
      'batch_id', p_batch_id,
      'committed_rows', 0,
      'failed_row_no', v_row_no,
      'sqlstate', v_sqlstate,
      'message', v_message
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'batch_id', p_batch_id,
    'status', 'committed',
    'committed_rows', v_committed,
    'blocked_rows', v_batch.error_rows,
    'committed_at', v_now,
    'undo_deadline', v_now + interval '24 hours',
    'error_report_path', v_report_path,
    'gr_next_value', v_after
  );
end;
$$;

revoke execute on function public.commit_import_batch(uuid) from public, anon;
grant execute on function public.commit_import_batch(uuid) to authenticated;

-- ── undo_import_batch ───────────────────────────────────────────────────
-- Role list is narrower than commit's, the same way FR-A15 made
-- restore_record narrower than soft_delete: the person who can silently
-- erase a day of a clerk's work is deliberately not everyone who can
-- create it.

create or replace function public.undo_import_batch(p_batch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_batch         public.import_batch%rowtype;
  v_student_ids   uuid[];
  v_enrolment_ids uuid[];
  v_blocker       text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_batch from public.import_batch
   where id = p_batch_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'IMPORT_BATCH_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_batch.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_batch.status <> 'committed' then
    raise exception 'IMPORT_BATCH_NOT_COMMITTED' using errcode = '55000';
  end if;

  -- AC5, first gate.
  if v_batch.undo_deadline is null or now() > v_batch.undo_deadline then
    raise exception 'UNDO_WINDOW_EXPIRED' using errcode = '55000',
      detail = format('undo_deadline=%s', v_batch.undo_deadline);
  end if;

  select coalesce(array_agg(student_id) filter (where student_id is not null), '{}'::uuid[]),
         coalesce(array_agg(enrolment_id) filter (where enrolment_id is not null), '{}'::uuid[])
    into v_student_ids, v_enrolment_ids
    from public.import_row where batch_id = p_batch_id;

  -- AC5, second gate. fee_plan is excluded on purpose - see the header.
  v_blocker := case
    when exists (select 1 from public.fee_challan     where enrolment_id = any(v_enrolment_ids)) then 'fee_challan'
    when exists (select 1 from public.fee_ledger      where enrolment_id = any(v_enrolment_ids)) then 'fee_ledger'
    when exists (select 1 from public.fee_payment     where enrolment_id = any(v_enrolment_ids)) then 'fee_payment'
    when exists (select 1 from public.concession_award where enrolment_id = any(v_enrolment_ids)) then 'concession_award'
    when exists (select 1 from public.attendance_day  where enrolment_id = any(v_enrolment_ids)) then 'attendance_day'
    else null
  end;
  if v_blocker is not null then
    raise exception 'UNDO_BLOCKED_BY_DEPENDENCY' using errcode = '55000', detail = format('table=%s', v_blocker);
  end if;

  -- import_row.student_id/enrolment_id are FKs onto the rows about to go.
  update public.import_row set student_id = null, enrolment_id = null where batch_id = p_batch_id;

  begin
    delete from public.enrolment  where id = any(v_enrolment_ids);
    delete from public.gr_ledger  where student_id = any(v_student_ids);
    delete from public.student    where id = any(v_student_ids);
  exception
    -- Anything referencing these rows that the list above does not name
    -- (a future marks/result table, most obviously) refuses the undo
    -- rather than crashing it. Re-raising here aborts the whole call, so
    -- the import_row detach above is discarded with it.
    when foreign_key_violation then
      raise exception 'UNDO_BLOCKED_BY_DEPENDENCY' using errcode = '55000',
        detail = 'referenced by other records (foreign_key_violation)';
  end;

  -- Only when nobody else has taken a number since; gr_sequence is meant
  -- to be gapless, so a rewind that would step on someone is simply not
  -- applied.
  update public.gr_sequence
     set next_value = v_batch.gr_next_value_before
   where campus_id = v_batch.campus_id
     and v_batch.gr_next_value_before is not null
     and next_value = v_batch.gr_next_value_after;

  update public.import_batch
     set status = 'undone', undone_at = now(), undone_by = auth.uid()
   where id = p_batch_id;

  return jsonb_build_object(
    'ok', true,
    'batch_id', p_batch_id,
    'students_removed', coalesce(array_length(v_student_ids, 1), 0),
    'enrolments_removed', coalesce(array_length(v_enrolment_ids, 1), 0)
  );
end;
$$;

revoke execute on function public.undo_import_batch(uuid) from public, anon;
grant execute on function public.undo_import_batch(uuid) to authenticated;

-- ── purge_import_staging ────────────────────────────────────────────────
-- import_row.raw is the school's spreadsheet cells - names, dates of birth
-- and B-Form numbers for children who may never be admitted. It has no
-- reason to outlive the import.

create or replace function public.purge_import_staging(p_older_than_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff   timestamptz := now() - make_interval(days => p_older_than_days);
  v_deleted  int;
  v_scrubbed int;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- A batch that never committed created nothing; its staged rows are
  -- pure PII with no provenance value and go entirely.
  delete from public.import_row r
   using public.import_batch b
   where b.id = r.batch_id
     and b.created_at < v_cutoff
     and b.status in ('validating', 'validated')
     and (app.auth_tenant_id() is null or b.tenant_id = app.auth_tenant_id());
  get diagnostics v_deleted = row_count;

  -- A committed batch keeps its skeleton - row_no, severity, student_id -
  -- because that is the only link from a live student back to the file
  -- they arrived in. The cells themselves are scrubbed.
  update public.import_row r
     set raw = '{}'::jsonb, normalised = '{}'::jsonb
    from public.import_batch b
   where b.id = r.batch_id
     and b.created_at < v_cutoff
     and b.status in ('committed', 'undone')
     and (app.auth_tenant_id() is null or b.tenant_id = app.auth_tenant_id())
     and (r.raw <> '{}'::jsonb or r.normalised <> '{}'::jsonb);
  get diagnostics v_scrubbed = row_count;

  return jsonb_build_object('rows_deleted', v_deleted, 'rows_scrubbed', v_scrubbed);
end;
$$;

revoke execute on function public.purge_import_staging(int) from public, anon;
grant execute on function public.purge_import_staging(int) to authenticated, service_role;

-- ── storage: the failure report ─────────────────────────────────────────
-- Same reserve-then-upload shape as the `imports` bucket: the path is
-- written onto import_batch by commit_import_batch, and the policies below
-- only admit an object whose name a batch row already claims, so a client
-- cannot write anywhere else in the bucket.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('import-errors', 'import-errors', false, 10485760, array['text/csv', 'text/plain'])
on conflict (id) do nothing;

create policy import_errors_read_campus on storage.objects
  for select to authenticated
  using (
    bucket_id = 'import-errors'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.import_batch b
       where b.error_report_path = objects.name
         and b.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or b.campus_id = any(app.auth_campus_ids()))
    )
  );

create policy import_errors_insert_officer on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'import-errors'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.import_batch b
       where b.error_report_path = objects.name and b.tenant_id = app.auth_tenant_id()
    )
  );

-- A re-uploaded report (a retried commit, a re-run of the same batch) is an
-- upsert, which storage issues as an UPDATE once the object exists.
create policy import_errors_update_officer on storage.objects
  for update to authenticated
  using (
    bucket_id = 'import-errors'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (
      select 1 from public.import_batch b
       where b.error_report_path = objects.name and b.tenant_id = app.auth_tenant_id()
    )
  );
