-- Two live cross-tenant holes, found by reading pg_class.relrowsecurity and
-- information_schema.role_table_grants against the running database rather
-- than by reading the migrations. Both were invisible to the entire pgTAP
-- suite because every existing test reaches these objects the legitimate
-- way: through the partitioned PARENT, or through a SECURITY DEFINER
-- function that runs as postgres and therefore bypasses RLS by definition.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 1. public.audit_log's partitions bypassed the parent entirely
-- ═══════════════════════════════════════════════════════════════════════
--
-- FR-A14 (20260729173206_audit_log_hardening.sql) made audit_log a monthly
-- range-partitioned table, enabled RLS on it, gave it a tenant-scoped read
-- policy (FR-T14 later widened that to campus scope) and revoked
-- INSERT/UPDATE/DELETE from authenticated/anon so only the SECURITY
-- DEFINER trigger can write. All of that was applied to the PARENT, and
-- none of it reaches a partition:
--
--   * `create table ... partition of ...` is an ordinary CREATE TABLE as
--     far as ACLs go. Supabase's ALTER DEFAULT PRIVILEGES on schema public
--     therefore handed every partition the full default grant set —
--     SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER — to
--     both anon and authenticated, undoing the parent's revoke.
--   * relrowsecurity is per-relation and starts false on a new partition.
--     `alter table <parent> enable row level security` does not set it on
--     children, and the parent's policies are not inherited either.
--   * Postgres applies a partition's OWN RLS (i.e. none) when the partition
--     is named directly in a query.
--
-- Net effect before this migration: `set role authenticated; select
-- count(*) from public.audit_log_2026_08` returned every tenant's audit
-- rows, and UPDATE/DELETE/TRUNCATE against the same name all succeeded.
-- The tamper-evident hash chain FR-T14 built could detect an edit
-- afterwards, but nothing refused one — and TRUNCATE leaves nothing behind
-- to verify, so it is not even detectable: a chain with zero rows verifies
-- 'ok'. FR-T08's guarantee that a refused certificate_issue DELETE is
-- *recorded to audit_log* was therefore recorded somewhere the accused
-- could empty.
--
-- ── revoke the direct grants, do not copy the policy ───────────────────
--
-- Two shapes close this. A partition can carry its own copy of
-- audit_log_tenant_scope, or the partition can simply stop being reachable
-- by name and leave the parent as the only door. This migration does the
-- latter, for three reasons:
--
--   1. It costs the legitimate path nothing. Postgres checks privileges on
--     the relation actually named in the query; a SELECT against the
--     parent does not consult the partitions' ACLs, and neither does tuple
--     routing on INSERT. Verified against this database: with SELECT
--     revoked from authenticated on all four partitions, an Owner's
--     `select ... from public.audit_log` still returns their rows and
--     app.tg_audit_row()'s parent-routed insert still lands.
--   2. A copied policy is a copy to keep in sync forever. audit_log's read
--      policy has already been rewritten once (FR-T14 added the campus
--      predicate); the next rewrite would have to remember N partitions
--      that grow by one every month, and a partition whose copy is stale
--      by one revision leaks exactly as widely as no policy at all. A
--      revoke cannot drift.
--   3. Duplicating the policy would still leave TRUNCATE open, because
--      TRUNCATE consults no policy at all (FR-T08's own finding).
--
-- RLS is nevertheless enabled on each partition, with no policy, as a
-- backstop rather than as the control: it is what stops the hole from
-- reopening the day someone runs the `grant ... on all tables in schema
-- public to authenticated` that Supabase's own docs suggest for other
-- purposes. Grants can come back by accident; deny-by-default does not.
--
-- ── TRUNCATE needs a trigger, per partition ────────────────────────────
--
-- service_role holds BYPASSRLS and every grant, so for it neither of the
-- above is the last word — the same reasoning FR-T02/FR-T08 already apply
-- to their own registers. TRUNCATE fires no row-level trigger and consults
-- no policy, so it needs a statement-level BEFORE TRUNCATE trigger, and
-- that trigger must exist on every partition individually: verified
-- against this database, a BEFORE TRUNCATE trigger on a partitioned parent
-- does NOT propagate to its partitions (unlike row-level triggers, which
-- do), so `truncate public.audit_log_2026_08` would sail past a
-- parent-only guard. The parent gets one too, since `truncate
-- public.audit_log` empties every partition in one statement — and
-- authenticated could run exactly that today, because FR-A14's revoke
-- listed insert, update and delete but not truncate.
--
-- ── secure by construction, not by enumeration ─────────────────────────
--
-- Fixing today's four partitions would regress on 1 September, when
-- create_audit_partition() mints audit_log_2026_11 with the default
-- privileges and relrowsecurity = false all over again. Since that
-- function is the only thing in the schema that creates a partition of
-- audit_log (audit_log_default, created inline by FR-A14, is the sole
-- exception and is retro-fitted below), it is the right and only seam:
-- app.secure_audit_log_partition() below is idempotent, is called by
-- create_audit_partition() on every invocation, and is applied here to
-- every partition that already exists — enumerated from pg_inherits, not
-- from a hand-written list that a future month would fall off.
--
-- A ddl_command_end EVENT TRIGGER would catch partitions created by any
-- route at all, including a future migration that writes `create table ...
-- partition of` by hand. It is deliberately not used: creating an event
-- trigger requires superuser, which the `postgres` role on hosted Supabase
-- is not, so the migration would apply locally and fail on deploy.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 2. Two counters had no RLS and full DML to authenticated
-- ═══════════════════════════════════════════════════════════════════════
--
-- public.application_no_counter (FR-B03, 20260730163812_admissions_pipeline
-- .sql) and public.employee_code_counter (FR-D01,
-- 20260730210318_staff_and_leave_types.sql) are the same object class as
-- certificate_serial_counter, gr_sequence, challan_counter,
-- enquiry_no_counter and fee_receipt_counter: a counter ROW rather than a
-- sequence, precisely so the increment is transactional and a failed
-- allocation hands the number back (FR-T02's header sets out the full
-- reasoning). Every other counter in that list has RLS enabled. These two
-- did not, and held the full default grant set, so any signed-in user of
-- any tenant could read every campus's counters and — the part that
-- matters — rewind one. next_seq or next_value set back by ten mints ten
-- duplicate application numbers or employee codes, and employee_code is
-- what settlement, gratuity and provident-fund history reference for the
-- life of the school.
--
-- The treatment is FR-T02's, adapted to how these two are actually
-- advanced, and layered in the order an attacker meets it:
--
--   1. RLS with an explicit deny-everything policy. Unlike
--      certificate_serial_counter there is no read policy: that counter
--      has a register page in the UI (v_certificate_serial_register),
--      these two have no reader at all, and the siblings closest to them
--      (enquiry_no_counter, challan_counter, fee_receipt_counter) are all
--      RLS-on-with-no-policy already. The policy is written out as
--      `using (false)` rather than left implicit so the denial is
--      greppable, per FR-T02's own convention.
--   2. A BEFORE INSERT/UPDATE/DELETE row trigger, which fires regardless
--      of caller and so covers service_role's BYPASSRLS.
--   3. The trigger's allow-list, narrow in the same three ways: the
--      executing role must be the table's owner (i.e. the context is a
--      SECURITY DEFINER function running as its owner, not a logged-in
--      role — the trigger is SECURITY INVOKER precisely so current_user
--      still reports the caller); the plpgsql call stack must contain a
--      frame for the specific allocator; and the change must be exactly
--      +1 with every other column byte-identical, so even a forged frame
--      could only do what allocation itself does. INSERT is allowed only
--      at the seed value, which makes "a series starts at one" structural;
--      DELETE is refused outright, including via an FK cascade from campus
--      or academic_session, because dropping the row restarts the series.
--      TRUNCATE gets its own statement-level trigger for the same reason
--      it does everywhere else in this schema.
--
-- The allocators are unchanged and keep working: fn_submit_application
-- (application numbers) and app.fn_next_employee_code (employee codes),
-- plus app.tg_seed_employee_code_counter, which seeds one row per campus.
-- All three are SECURITY DEFINER owned by postgres, so all three satisfy
-- the owner check, and each is named in the allow-list of the counter it
-- touches.
--
-- Errcodes are 42501 throughout, never class 55: PostgREST maps SQLSTATE
-- class 55 to HTTP 500 and replaces the body with "Something went wrong",
-- so a class-55 refusal would reach the browser as a crash.

-- ═══════════════════════════════════════════════════════════════════════
-- audit_log: the TRUNCATE guard, the securing helper, the retro-fit
-- ═══════════════════════════════════════════════════════════════════════

-- Shared by the parent and every partition; tg_table_name names whichever
-- relation was actually targeted, so one function serves all of them.
create or replace function app.tg_audit_log_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'audit_log is append-only'
    using errcode = '42501',
          detail = format('truncate of %I.%I by %s', tg_table_schema, tg_table_name, current_user),
          hint = 'The audit trail is tamper-evident; emptying it destroys the chain it is verified against.';
end;
$$;

-- Idempotent, so create_audit_partition() can call it unconditionally and
-- so re-running it over an already-secured partition is a no-op.
create or replace function app.secure_audit_log_partition(p_partition text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  execute format('revoke all on public.%I from public, anon, authenticated', p_partition);
  execute format('alter table public.%I enable row level security', p_partition);

  if not exists (
    select 1
      from pg_catalog.pg_trigger t
      join pg_catalog.pg_class c on c.oid = t.tgrelid
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relname = p_partition
       and t.tgname = 'trg_audit_log_partition_no_truncate'
  ) then
    execute format(
      'create trigger trg_audit_log_partition_no_truncate before truncate on public.%I '
      'for each statement execute function app.tg_audit_log_no_truncate()',
      p_partition
    );
  end if;
end;
$$;

revoke execute on function app.secure_audit_log_partition(text) from public, anon, authenticated;

-- Same signature as before (one defaulted argument), so this is a genuine
-- replacement rather than a second overload — adding an argument here
-- would make the three call sites in FR-A14's own migration ambiguous.
create or replace function public.create_audit_partition(p_month date default date_trunc('month', now())::date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end   date := (date_trunc('month', p_month) + interval '1 month')::date;
  v_name  text := 'audit_log_' || to_char(v_start, 'YYYY_MM');
begin
  if not exists (select 1 from pg_catalog.pg_class where relname = v_name) then
    execute format(
      'create table public.%I partition of public.audit_log for values from (%L) to (%L)',
      v_name, v_start, v_end
    );
  end if;

  -- Unconditional, not inside the branch above: a partition that already
  -- exists but predates this migration gets secured too, and a partition
  -- created by any other route is repaired the next time the month rolls.
  perform app.secure_audit_log_partition(v_name);
end;
$$;

-- Enumerated from the catalogue rather than from a list of four names, so
-- audit_log_default (created inline by FR-A14, never through
-- create_audit_partition) is covered by the same pass.
do $$
declare
  v_partition text;
begin
  for v_partition in
    select child.relname
      from pg_catalog.pg_inherits i
      join pg_catalog.pg_class child  on child.oid = i.inhrelid
      join pg_catalog.pg_class parent on parent.oid = i.inhparent
      join pg_catalog.pg_namespace n  on n.oid = parent.relnamespace
     where n.nspname = 'public' and parent.relname = 'audit_log'
     order by 1
  loop
    perform app.secure_audit_log_partition(v_partition);
  end loop;
end;
$$;

-- The parent kept TRUNCATE (FR-A14 revoked only insert, update and delete)
-- and REFERENCES/TRIGGER, none of which any application role has a use
-- for. SELECT, filtered by audit_log_tenant_scope, is the whole of the
-- legitimate authenticated surface — FR-T14's export reads the rows with a
-- plain RLS-governed SELECT from the requester's own session.
revoke all on public.audit_log from public, anon, authenticated;
grant select on public.audit_log to authenticated;

create trigger trg_audit_log_no_truncate
  before truncate on public.audit_log
  for each statement execute function app.tg_audit_log_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- application_no_counter
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_application_no_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  if tg_op = 'DELETE' then
    raise exception 'application number counters are advanced only by fn_submit_application()'
      using errcode = '42501',
            detail = format('delete of counter campus=%s session=%s at %s',
                            old.campus_id, old.session_id, old.next_seq),
            hint = 'Deleting a counter restarts the series and reissues application numbers already handed to families.';
  end if;

  if tg_op = 'INSERT' then
    -- The allocator seeds with the column default and immediately walks it
    -- up one at a time; a series that could be seeded part-way up is a
    -- series whose numbering can be jumped in a single statement.
    if new.next_seq <> 1 then
      raise exception 'application number counters are advanced only by fn_submit_application()'
        using errcode = '42501',
              detail = format('series seeded at %s', new.next_seq),
              hint = 'An application-number series must start at one and advance one application at a time.';
    end if;
    return new;
  end if;

  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if current_user = v_owner
     and v_stack ~ 'function public\.fn_submit_application\('
     and new.next_seq = old.next_seq + 1
     and new.campus_id  is not distinct from old.campus_id
     and new.session_id is not distinct from old.session_id
  then
    return new;
  end if;

  raise exception 'application number counters are advanced only by fn_submit_application()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.next_seq, new.next_seq, current_user),
          hint = 'Application numbers are allocated one at a time, inside the transaction that files the application.';
end;
$$;

create trigger trg_block_manual_application_no_edit
  before insert or update or delete on public.application_no_counter
  for each row execute function app.tg_block_manual_application_no_edit();

-- ═══════════════════════════════════════════════════════════════════════
-- employee_code_counter
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_employee_code_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  if tg_op = 'DELETE' then
    raise exception 'employee code counters are advanced only by app.fn_next_employee_code()'
      using errcode = '42501',
            detail = format('delete of counter campus=%s at %s', old.campus_id, old.next_value),
            hint = 'Deleting a counter restarts the series and reissues employee codes that payroll and provident-fund history already reference.';
  end if;

  if tg_op = 'INSERT' then
    if new.next_value <> 1 then
      raise exception 'employee code counters are advanced only by app.fn_next_employee_code()'
        using errcode = '42501',
              detail = format('series seeded at %s', new.next_value),
              hint = 'An employee-code series must start at one and advance one hire at a time.';
    end if;
    return new;
  end if;

  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if current_user = v_owner
     and v_stack ~ 'function app\.fn_next_employee_code\('
     and new.next_value = old.next_value + 1
     and new.campus_id is not distinct from old.campus_id
  then
    return new;
  end if;

  raise exception 'employee code counters are advanced only by app.fn_next_employee_code()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.next_value, new.next_value, current_user),
          hint = 'Employee codes are allocated one at a time, inside the transaction that creates the staff record.';
end;
$$;

create trigger trg_block_manual_employee_code_edit
  before insert or update or delete on public.employee_code_counter
  for each row execute function app.tg_block_manual_employee_code_edit();

-- ═══════════════════════════════════════════════════════════════════════
-- Counters: TRUNCATE and RLS
-- ═══════════════════════════════════════════════════════════════════════

-- Shared by both counters. TRUNCATE fires no row-level trigger and is
-- filtered by no policy, so without this the two triggers above are one
-- statement away from irrelevant — and TRUNCATE ... CASCADE reaches these
-- tables from campus and academic_session, not only by name.
create or replace function app.tg_counter_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'number counters cannot be truncated'
    using errcode = '42501',
          detail = format('truncate of %I.%I by %s', tg_table_schema, tg_table_name, current_user),
          hint = 'Emptying a counter restarts its series and reissues numbers that are already in use.';
end;
$$;

create trigger trg_application_no_counter_no_truncate
  before truncate on public.application_no_counter
  for each statement execute function app.tg_counter_no_truncate();

create trigger trg_employee_code_counter_no_truncate
  before truncate on public.employee_code_counter
  for each statement execute function app.tg_counter_no_truncate();

alter table public.application_no_counter enable row level security;
alter table public.employee_code_counter enable row level security;

-- Nothing in the application reads these — the allocators are SECURITY
-- DEFINER and read them as the owner — so the policies deny outright
-- rather than scope. Written out instead of left implicit so the denial is
-- greppable, per FR-T02's convention.
create policy application_no_counter_no_direct_access on public.application_no_counter
  for all to authenticated
  using (false)
  with check (false);

create policy employee_code_counter_no_direct_access on public.employee_code_counter
  for all to authenticated
  using (false)
  with check (false);
