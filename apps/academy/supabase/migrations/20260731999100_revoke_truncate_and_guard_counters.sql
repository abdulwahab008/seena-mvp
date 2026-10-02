-- A schema-wide cross-tenant data-destruction hole, found the same way
-- 20260731999000 found its two: by reading
-- information_schema.role_table_grants against the running database rather
-- than the migrations, and then running the statement.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 1. Every table in public could be emptied by any signed-in user
-- ═══════════════════════════════════════════════════════════════════════
--
-- Supabase's stock `alter default privileges in schema public grant all on
-- tables to anon, authenticated, service_role` hands every new table the
-- full privilege set, TRUNCATE included, and **no RLS policy can gate
-- TRUNCATE** — Postgres checks the table privilege and nothing else.
-- Proven live against this database: a session holding only the
-- subject_teacher role ran
--
--     truncate public.student cascade;
--
-- and it cascaded through roughly forty-four tables — fee_ledger,
-- mark_entry, attendance_day, fee_payment among them — stopping only when
-- the FK graph reached certificate_issue, whose own BEFORE TRUNCATE guard
-- (FR-T08) refused. Every table without such a guard was emptiable, across
-- every tenant, by one statement from any account. Tenant isolation, the
-- append-only registers, the tamper-evident audit chain and the gapless
-- number series were all one word away from gone; and TRUNCATE, unlike
-- DELETE, fires no row trigger, so nothing recorded the attempt either.
--
-- The eleven BEFORE TRUNCATE triggers this schema had accumulated
-- (certificate_issue, mark_entry_audit, mark_lock, mark_unlock_request,
-- consent_record, grading_band, expense_voucher_approval, the three ocr_*
-- tables, and audit_log with its partitions) were each written as
-- belt-and-braces against service_role for one specific register. They
-- were, accidentally, the only thing standing between a logged-in user and
-- the whole database. That is the wrong control at the wrong layer: the
-- privilege should never have been held in the first place.
--
-- ── the revoke, and why the default-privileges half is the real fix ─────
--
-- `revoke truncate on all tables in schema public` closes it for the 186
-- tables that exist today. On its own it regresses the moment the next
-- migration writes `create table`, because ALL TABLES is expanded once, at
-- execution, and the *default* ACL is what a new relation inherits. So the
-- durable half is ALTER DEFAULT PRIVILEGES, which rewrites what future
-- relations are born with.
--
-- Default privileges are keyed by the role that creates the object, so the
-- right role has to be named. Every one of the 186 tables in public is
-- owned by `postgres`, and `supabase db reset`, `supabase db push` and the
-- hosted migration runner all connect as `postgres` — so `for role
-- postgres` is the entry that governs anything this project will ever
-- create. pg_default_acl also carries a second entry for schema public
-- created by `supabase_admin` (the platform's own bootstrap), which would
-- govern a table created by that role. `postgres` is not a member of
-- `supabase_admin` and is not a superuser on Supabase — hosted or local —
-- so it cannot alter that entry; the attempt below is wrapped so the
-- migration applies cleanly where it is refused and takes effect where a
-- superuser runs it (a dump restore, a self-hosted deployment). Nothing in
-- this application creates tables as supabase_admin, so the postgres entry
-- is the one that matters.
--
-- ── TRIGGER and REFERENCES go too ──────────────────────────────────────
--
-- The same default grant hands anon and authenticated TRIGGER and
-- REFERENCES on all 186 tables. 20260731999000 revoked them on audit_log
-- and its partitions and left them everywhere else. They go schema-wide
-- here, for the same reason as TRUNCATE rather than a lesser one: no
-- PostgREST client has ever needed either. TRIGGER lets a holder attach
-- executable code to a table they should only read — every write to it
-- then runs code of their choosing, inside the writer's transaction and
-- (for a SECURITY DEFINER trigger function) potentially outside RLS.
-- REFERENCES lets a holder point a foreign key at another tenant's rows,
-- which both probes for the existence of key values and lets them wedge
-- the referenced row against deletion. Both currently need CREATE on some
-- schema to exploit and `authenticated` has CREATE on neither public nor
-- app — but that is a second control doing this one's job, exactly the
-- arrangement that made the TRUNCATE hole survive 130 test files. Held
-- privileges that nothing uses are removed.
--
-- MAINTAIN (Postgres 17) is left alone: VACUUM/ANALYZE/REINDEX on a table
-- destroys nothing and reveals nothing.
--
-- service_role keeps everything. It holds BYPASSRLS by design, legitimate
-- server-side code runs as it, and narrowing it here would break the app
-- rather than the attacker. Its containment is triggers, below.
--
-- ── belt-and-braces triggers: a bounded list, not 186 ───────────────────
--
-- Because service_role still truncates, the revoke is necessary and not
-- sufficient, and the house pattern is a BEFORE TRUNCATE statement
-- trigger. Applying one to all 186 tables was rejected: the list would
-- have to be maintained by enumeration forever, a ddl_command_end event
-- trigger cannot automate it (creating one requires superuser, which
-- `postgres` on hosted Supabase is not — 20260731999000's finding), and so
-- the coverage would silently lapse on the first table a future migration
-- adds. A guarantee that decays is worse than a stated boundary.
--
-- The triggers therefore go on the tables where destruction is
-- unrecoverable *from anything else in this schema*: the money actually
-- received or owed, the marks as the teacher entered them, the statutory
-- registers, and the number counters. Derived tables are deliberately
-- excluded — subject_result, annual_result, result_position and
-- attendance_month_summary recompute from mark_entry and attendance_day;
-- fee_challan_pdf regenerates from fee_challan. Configuration tables
-- (fee_head, class_level, subject, templates) are re-enterable. Both
-- classes are protected from clients by the revoke above; only their
-- last-resort protection from service_role is what is being scoped here.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 2. Four number counters had no append-only guard at all
-- ═══════════════════════════════════════════════════════════════════════
--
-- gr_sequence (FR-C01), enquiry_no_counter (FR-B01), challan_counter
-- (FR-K10) and fee_receipt_counter (FR-K12) are the same object class as
-- certificate_serial_counter, application_no_counter and
-- employee_code_counter: a counter ROW rather than a Postgres SEQUENCE,
-- chosen precisely so allocation is transactional and gapless. All four
-- had RLS enabled, which denies ordinary DML — and nothing else. So
-- `update public.gr_sequence set next_value = 1` as service_role returned
-- `UPDATE 17`, silently arming seventeen campuses to reissue GR numbers
-- that are cited in board correspondence and legal disputes; and all four
-- truncated successfully as `authenticated`.
--
-- certificate_serial_counter had FR-T02's full row-level guard and, alone
-- among the seven, no TRUNCATE guard — so `truncate
-- public.certificate_serial_counter` as authenticated reset every campus's
-- certificate series to zero, which is the exact outcome its elaborate
-- DELETE refusal exists to prevent.
--
-- Each of the four gets FR-T02's shape, layered in the order an attacker
-- meets it: a BEFORE INSERT/UPDATE/DELETE row trigger that fires
-- regardless of caller (so it covers service_role's BYPASSRLS); an
-- allow-list narrowed three ways — the executing role must be the table's
-- owner (i.e. the context is a SECURITY DEFINER function running as its
-- definer, not a logged-in role; the trigger is SECURITY INVOKER so
-- current_user still reports the caller), the plpgsql call stack must
-- carry a frame for a named allocator, and the change itself must be
-- bounded to what that allocator does; and a statement-level TRUNCATE
-- trigger, because TRUNCATE fires no row trigger and consults no policy.
--
-- The real allocators, found from pg_proc rather than assumed, and all
-- SECURITY DEFINER owned by postgres unless noted:
--
--   enquiry_no_counter   public.fn_next_enquiry_no() — one
--                        `insert ... on conflict do update`, so it seeds a
--                        new series at next_seq = 2 (it returns
--                        next_seq - 1, making the first enquiry number 1)
--                        and advances by one thereafter.
--   challan_counter      public.next_challan_no() — seeds last_no = 0,
--                        then +1 under SELECT ... FOR UPDATE.
--   fee_receipt_counter  app.fn_next_receipt_no() — seeds 0 then +1. This
--                        one is SECURITY INVOKER, but its only caller is
--                        public.collect_cash_payment(), which is SECURITY
--                        DEFINER owned by postgres, so current_user is
--                        already postgres by the time the counter is
--                        touched and both frames are on the stack.
--   gr_sequence          four legitimate writers, not one, which is why
--                        its allow-list is a list:
--                          app.tg_seed_gr_sequence()   INSERT at 1, fired
--                            by the campus insert trigger.
--                          app.fn_allocate_gr_number() +1, per admission.
--                          public.commit_import_batch() forward jump — a
--                            bulk import takes a contiguous block in one
--                            UPDATE.
--                          public.undo_import_batch() rewind — undoing an
--                            import hands the block back, and only when
--                            nobody has taken a number since (that
--                            function's own WHERE clause).
--                          public.set_gr_sequence() arbitrary — the
--                            documented "school migrating from a paper
--                            register" path. It stays arbitrary because
--                            that is its purpose, but it is role-checked
--                            and campus-scoped inside the function, and
--                            requiring the frame is what closes the hole:
--                            service_role's raw UPDATE has no frame, and
--                            service_role calling set_gr_sequence() gets
--                            FORBIDDEN from app.auth_role().
--
-- DELETE is refused outright on all four, including via an FK cascade from
-- campus, tenant or academic_session, on the same grounds
-- 20260731999000 and FR-T02 already take for their counters: dropping the
-- row restarts the series and reissues numbers that are already on paper.
-- For gr_sequence this means a campus is uncascadable from the moment it
-- exists (its counter is seeded by a trigger on campus insert) rather than
-- from its first admission; no application or test path hard-deletes a
-- campus, and the two that assert the cascade is refused already assert it
-- by errcode.
--
-- Errcodes are 42501 throughout, never class 55: PostgREST maps SQLSTATE
-- class 55 to HTTP 500 and replaces the body with a generic message, so a
-- class-55 refusal reaches the browser as a crash.

-- ═══════════════════════════════════════════════════════════════════════
-- The revoke, and the default privileges that keep it revoked
-- ═══════════════════════════════════════════════════════════════════════

revoke truncate, trigger, references on all tables in schema public from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke truncate, trigger, references on tables from anon, authenticated;

-- Applies where a superuser runs this migration and is a documented no-op
-- where postgres does not hold membership of supabase_admin, which is the
-- case on both hosted and local Supabase. Swallowing only
-- insufficient_privilege, so a different failure still stops the migration.
do $$
begin
  execute 'alter default privileges for role supabase_admin in schema public '
          'revoke truncate, trigger, references on tables from anon, authenticated';
exception when insufficient_privilege then
  raise notice 'default privileges for supabase_admin left unchanged: postgres is not a member of it';
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- Belt-and-braces: TRUNCATE guards on the irreplaceable tables
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_table_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'table %.% cannot be truncated', tg_table_schema, tg_table_name
    using errcode = '42501',
          detail = format('truncate of %I.%I by %s', tg_table_schema, tg_table_name, current_user),
          hint = 'This table is a record of money, marks or a statutory register; nothing in the schema can rebuild it.';
end;
$$;

-- Idempotent so that re-running it, or adding a table to the list below in
-- a later migration, is safe.
create or replace function app.guard_table_truncate(p_table text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = p_table
       and t.tgname = 'trg_' || p_table || '_no_truncate'
  ) then
    execute format(
      'create trigger %I before truncate on public.%I '
      'for each statement execute function app.tg_table_no_truncate()',
      'trg_' || p_table || '_no_truncate', p_table
    );
  end if;
end;
$$;

revoke execute on function app.guard_table_truncate(text) from public, anon, authenticated;

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    -- money received, owed, or paid out
    'fee_ledger', 'fee_payment', 'fee_payment_allocation', 'fee_receipt',
    'fee_challan', 'fee_challan_line', 'cash_book_day', 'expense_voucher',
    -- marks as entered, and the trail of who touched attendance
    'mark_entry', 'attendance_audit',
    -- the statutory registers
    'student', 'gr_ledger', 'enrolment', 'attendance_day', 'staff'
  ]
  loop
    perform app.guard_table_truncate(v_table);
  end loop;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- certificate_serial_counter: the one guard FR-T02 was missing
-- ═══════════════════════════════════════════════════════════════════════

create trigger trg_certificate_serial_counter_no_truncate
  before truncate on public.certificate_serial_counter
  for each statement execute function app.tg_counter_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- enquiry_no_counter
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_enquiry_no_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if tg_op = 'DELETE' then
    raise exception 'enquiry number counters are advanced only by fn_next_enquiry_no()'
      using errcode = '42501',
            detail = format('delete of counter campus=%s session=%s at %s',
                            old.campus_id, old.session_id, old.next_seq),
            hint = 'Deleting a counter restarts the series and reissues enquiry numbers already quoted to families.';
  end if;

  if tg_op = 'INSERT' then
    -- The allocator's `insert ... on conflict do update` claims the first
    -- number as it seeds, so a fresh series is born at two, never higher:
    -- a series that could be seeded part-way up is a series whose
    -- numbering can be jumped in one statement.
    if current_user = v_owner
       and v_stack ~ 'function public\.fn_next_enquiry_no\('
       and new.next_seq = 2
    then
      return new;
    end if;

    raise exception 'enquiry number counters are advanced only by fn_next_enquiry_no()'
      using errcode = '42501',
            detail = format('series seeded at %s by %s', new.next_seq, current_user),
            hint = 'An enquiry-number series starts when the first enquiry is filed and advances one enquiry at a time.';
  end if;

  if current_user = v_owner
     and v_stack ~ 'function public\.fn_next_enquiry_no\('
     and new.next_seq = old.next_seq + 1
     and new.campus_id  is not distinct from old.campus_id
     and new.session_id is not distinct from old.session_id
  then
    return new;
  end if;

  raise exception 'enquiry number counters are advanced only by fn_next_enquiry_no()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.next_seq, new.next_seq, current_user),
          hint = 'Enquiry numbers are allocated one at a time, inside the transaction that files the enquiry.';
end;
$$;

create trigger trg_block_manual_enquiry_no_edit
  before insert or update or delete on public.enquiry_no_counter
  for each row execute function app.tg_block_manual_enquiry_no_edit();

create trigger trg_enquiry_no_counter_no_truncate
  before truncate on public.enquiry_no_counter
  for each statement execute function app.tg_counter_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- challan_counter
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_challan_no_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if tg_op = 'DELETE' then
    raise exception 'challan number counters are advanced only by next_challan_no()'
      using errcode = '42501',
            detail = format('delete of counter campus=%s session=%s at %s',
                            old.campus_id, old.session_id, old.last_no),
            hint = 'Deleting a counter restarts the series and reissues challan numbers the bank already holds.';
  end if;

  if tg_op = 'INSERT' then
    if current_user = v_owner
       and v_stack ~ 'function public\.next_challan_no\('
       and new.last_no = 0
    then
      return new;
    end if;

    raise exception 'challan number counters are advanced only by next_challan_no()'
      using errcode = '42501',
            detail = format('series seeded at %s by %s', new.last_no, current_user),
            hint = 'A challan-number series must start at zero and advance one challan at a time.';
  end if;

  if current_user = v_owner
     and v_stack ~ 'function public\.next_challan_no\('
     and new.last_no = old.last_no + 1
     and new.tenant_id  is not distinct from old.tenant_id
     and new.campus_id  is not distinct from old.campus_id
     and new.session_id is not distinct from old.session_id
  then
    return new;
  end if;

  raise exception 'challan number counters are advanced only by next_challan_no()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.last_no, new.last_no, current_user),
          hint = 'Challan numbers carry a check digit the bank validates; reissuing one makes two demands collide.';
end;
$$;

create trigger trg_block_manual_challan_no_edit
  before insert or update or delete on public.challan_counter
  for each row execute function app.tg_block_manual_challan_no_edit();

create trigger trg_challan_counter_no_truncate
  before truncate on public.challan_counter
  for each statement execute function app.tg_counter_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- fee_receipt_counter
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_receipt_no_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if tg_op = 'DELETE' then
    raise exception 'receipt number counters are advanced only by app.fn_next_receipt_no()'
      using errcode = '42501',
            detail = format('delete of counter campus=%s session=%s at %s',
                            old.campus_id, old.session_id, old.last_no),
            hint = 'Deleting a counter restarts the series and reissues receipt numbers already handed over the counter.';
  end if;

  if tg_op = 'INSERT' then
    if current_user = v_owner
       and v_stack ~ 'function app\.fn_next_receipt_no\('
       and new.last_no = 0
    then
      return new;
    end if;

    raise exception 'receipt number counters are advanced only by app.fn_next_receipt_no()'
      using errcode = '42501',
            detail = format('series seeded at %s by %s', new.last_no, current_user),
            hint = 'A receipt-number series must start at zero and advance one payment at a time.';
  end if;

  if current_user = v_owner
     and v_stack ~ 'function app\.fn_next_receipt_no\('
     and new.last_no = old.last_no + 1
     and new.tenant_id  is not distinct from old.tenant_id
     and new.campus_id  is not distinct from old.campus_id
     and new.session_id is not distinct from old.session_id
  then
    return new;
  end if;

  raise exception 'receipt number counters are advanced only by app.fn_next_receipt_no()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.last_no, new.last_no, current_user),
          hint = 'Receipt numbers are the cash book''s index; two payments under one number cannot be reconciled.';
end;
$$;

create trigger trg_block_manual_receipt_no_edit
  before insert or update or delete on public.fee_receipt_counter
  for each row execute function app.tg_block_manual_receipt_no_edit();

create trigger trg_fee_receipt_counter_no_truncate
  before truncate on public.fee_receipt_counter
  for each statement execute function app.tg_counter_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- gr_sequence
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_gr_sequence_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if tg_op = 'DELETE' then
    raise exception 'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()'
      using errcode = '42501',
            detail = format('delete of sequence campus=%s at %s', old.campus_id, old.next_value),
            hint = 'Deleting a GR sequence restarts the register at one and reissues numbers cited in board correspondence.';
  end if;

  if tg_op = 'INSERT' then
    -- One row per campus, seeded by the campus insert trigger at one; a
    -- register that could be seeded part-way up is a register whose
    -- numbering can be jumped without any allocation happening.
    if current_user = v_owner
       and v_stack ~ 'function app\.tg_seed_gr_sequence\('
       and new.next_value = 1
    then
      return new;
    end if;

    raise exception 'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()'
      using errcode = '42501',
            detail = format('sequence seeded at %s by %s', new.next_value, current_user),
            hint = 'A campus GR register starts at one when the campus is created; use set_gr_sequence() to carry a paper register forward.';
  end if;

  -- Four legitimate writers, each bounded to what it actually does, so a
  -- forged frame buys no more than the real path would.
  if current_user = v_owner
     and new.tenant_id is not distinct from old.tenant_id
     and new.campus_id is not distinct from old.campus_id
     and (
       -- one admission
       (v_stack ~ 'function app\.fn_allocate_gr_number\('
        and new.next_value = old.next_value + 1
        and new.prefix    is not distinct from old.prefix
        and new.pad_width is not distinct from old.pad_width)
       -- a bulk import taking a contiguous block in one statement
       or (v_stack ~ 'function public\.commit_import_batch\('
        and new.next_value >= old.next_value
        and new.prefix    is not distinct from old.prefix
        and new.pad_width is not distinct from old.pad_width)
       -- undoing that import, handing the block back
       or (v_stack ~ 'function public\.undo_import_batch\('
        and new.next_value <= old.next_value
        and new.prefix    is not distinct from old.prefix
        and new.pad_width is not distinct from old.pad_width)
       -- carrying a paper register forward: prefix, width and start are
       -- the whole point of this call, so only the keys are pinned
       or v_stack ~ 'function public\.set_gr_sequence\('
     )
  then
    return new;
  end if;

  raise exception 'GR sequences are advanced only by app.fn_allocate_gr_number() and set_gr_sequence()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.next_value, new.next_value, current_user),
          hint = 'GR numbers are allocated one at a time inside the admission; changing the series is set_gr_sequence()''s job, and it checks the caller''s role and campus.';
end;
$$;

create trigger trg_block_manual_gr_sequence_edit
  before insert or update or delete on public.gr_sequence
  for each row execute function app.tg_block_manual_gr_sequence_edit();

create trigger trg_gr_sequence_no_truncate
  before truncate on public.gr_sequence
  for each statement execute function app.tg_counter_no_truncate();
