-- FR-T14: audit trail export for inspection.
--
-- "As an Owner, I want to export a signed, complete audit trail for a date
-- range and entity, so that when an auditor or a court asks who changed a
-- fee or a mark and when, I can produce evidence rather than a screenshot."
--
-- What already existed before this migration (20260729135955_foundation.sql,
-- 20260729173206_audit_log_hardening.sql): the whole audit-logging
-- backbone. public.audit_log is a monthly range-partitioned table with
-- tenant_id, campus_id, occurred_at, actor_user_id, actor_role, action,
-- table_name, row_id, before, after, changed_columns — every column this
-- FR's "who changed a fee or a mark and when" story needs. app.tg_audit_row()
-- is already attached (as an AFTER INSERT/UPDATE/DELETE trigger) to ~70
-- tables across every module, including fee_challan. Redaction
-- (audit_redacted_column), hard write denial (INSERT/UPDATE/DELETE revoked
-- from authenticated/anon — only the SECURITY DEFINER trigger can write),
-- and tenant-scoped read RLS all already exist and are already tested
-- (audit_log_hardening.test.sql). This migration does NOT create a second,
-- parallel audit-logging system — everything below extends the existing
-- one.
--
-- The real gaps this migration closes:
--
--   1. No hash-chain. audit_log had no prev_hash/row_hash columns at all —
--      a row could be UPDATEd directly in SQL (by a superuser bypassing the
--      authenticated-role grant revocation, e.g. a DBA with a support
--      ticket, or a compromised service_role key) with nothing to detect
--      it. Added below: prev_hash/row_hash columns, a pure hash function
--      (app.fn_audit_row_hash, shared by the trigger and the verifier so
--      the two can never drift apart), app.tg_audit_row() rewritten to
--      chain each new row onto the previous one (per tenant — see its own
--      comment below for why per-tenant, not one global chain), and
--      run_audit_chain_verification() — the nightly job, real and tested,
--      un-scheduled like every other System-actor function this session
--      has built (no pg_cron locally: run_unmarked_attendance_check,
--      dispatch_absentee_notifications, purge_soft_deleted_records, ...).
--
--   2. campus_id was a column on audit_log that nothing ever populated —
--      every row's campus_id was NULL, and the read RLS policy
--      (audit_log_tenant_scope) checked only tenant_id, so a Principal
--      scoped to one campus could already read every OTHER campus's audit
--      trail in their tenant. Fixed by populating campus_id in the trigger
--      (same coalesce-from-NEW/OLD shape tenant_id already uses, plus the
--      same "the table itself has no campus_id column, fall back to its
--      own id" special case tenant_id uses for the tenant table, mirrored
--      here for the campus table) and widening audit_log_tenant_scope with
--      the same guard used ~60 other places in this schema
--      (per_campus_role_scoping.sql's own header), with one deliberate
--      addition: a row whose campus_id is null (audit_log also covers
--      genuinely tenant-wide tables with no campus concept — class_level,
--      fee_head, role, ...) stays visible to Principal too, not just
--      owner/super_admin — see the policy's own comment for why.
--
--   3. No export mechanism at all. Added: public.audit_export_job (a
--      job-status table, same shape as fee_challan_batch/purge_hold —
--      request now, a worker fills in the result later),
--      request_audit_export() to create one, and complete_audit_export()/
--      fail_audit_export() for the worker to report back. The actual data
--      read is NOT a new RPC — every other RPC in this codebase is
--      SECURITY DEFINER specifically so it can enforce its own scope
--      checks and bypass RLS; the one deliberate exception in this
--      migration is that the audit rows themselves are read straight off
--      public.audit_log via a plain RLS-governed SELECT, from the
--      requester's own authenticated session (apps/academy/app/(app)/
--      audit-export/actions.ts). That is what AC3 literally asks for — "zero
--      rows returned by RLS rather than an authorisation error" — and it
--      only works because gap #2 above made audit_log's own RLS
--      campus-aware. A Principal who requests campus B while scoped to
--      campus A gets a real job that completes with row_count 0, not a
--      FORBIDDEN error: request_audit_export() only gates on role, never
--      on p_campus_id vs. the caller's own scope.
--
-- Storage / async / notification — what's real vs. what's a stand-in, and
-- why, given this environment (local Supabase, no pg_cron, no deployed
-- Edge Functions runtime):
--   * A private 'audit-exports' Storage bucket is created for real, with
--     RLS on storage.objects (same posture as FR-A18's branding bucket).
--     Files are written by the requester's own authenticated client
--     (apps/academy/app/(app)/audit-export/actions.ts), never through a
--     service-role code path — there's no reason to invent one when the
--     RLS-governed authenticated upload this codebase already uses for
--     branding works identically here.
--   * The row fetch is real keyset pagination (occurred_at, id) — never an
--     OFFSET scan — so the loop that builds the export never holds more
--     than one page in memory regardless of how many rows exist in total.
--     That is the one part of "handles 2.4M rows" that's actually
--     mechanically true here.
--   * What is NOT real, flagged rather than faked: true asynchronous
--     execution off the request/response cycle (a queue, a background
--     worker, an Edge Function) does not exist in this environment to host
--     it, so the export currently runs to completion inside the same
--     server action that requested it. request_audit_export() and
--     complete_audit_export()/fail_audit_export() are the seam a real
--     worker would sit behind — swapping the synchronous loop for "enqueue
--     the job, have a worker call complete_audit_export() when done" is an
--     infrastructure change, not a data-model one. Likewise, "completes
--     within 15 minutes for 2.4M rows" is not something this local
--     environment can produce or measure — there is no 2.4M-row dataset
--     and no realistic infrastructure to time it against; asserting a
--     number here would be fabricating a benchmark, not running one.
--   * "The requester is notified" has no email/SMS/push provider
--     integrated anywhere in this codebase (the same gap FR-G12's
--     attendance_notification outbox already documents for SMS) — the
--     completed audit_export_job row (status, row_count, download_url,
--     download_expires_at) IS the notification surface: the requester's
--     own Audit Export page lists it. A real provider integration is a
--     separate, unscoped feature.
--
-- 'certificate_issue' (this FR's own example entity, module T) has no
-- table yet — module T has no other shipped FRs. table_name is (and
-- already was) a plain text column on audit_log, not a foreign key to a
-- fixed catalogue, so nothing here special-cases it: requesting
-- 'certificate_issue' today returns a real, correctly-empty result (zero
-- matching rows, not an error) because nothing writes to it yet. The
-- moment a future FR adds a certificate_issue table with
-- `execute function app.tg_audit_row()` attached, exports pick it up with
-- no change here.

-- ═══════════════════════════════════════════════════════════════════════
-- 1. Hash chain: columns, pure hash function, trigger rewrite
-- ═══════════════════════════════════════════════════════════════════════

alter table public.audit_log add column prev_hash text, add column row_hash text;

-- Pure — same inputs always produce the same digest — so the trigger (at
-- write time) and run_audit_chain_verification() (at read time) can share
-- one definition instead of two hand-maintained copies that could drift.
-- Not security definer: it touches no table, only its own arguments.
create or replace function app.fn_audit_row_hash(
  p_prev_hash       text,
  p_tenant_id       uuid,
  p_campus_id       uuid,
  p_occurred_at     timestamptz,
  p_actor_user_id   uuid,
  p_actor_role      text,
  p_action          text,
  p_table_name      text,
  p_row_id          uuid,
  p_before          jsonb,
  p_after           jsonb,
  p_changed_columns text[]
)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(
    sha256(
      convert_to(
        coalesce(p_prev_hash, 'GENESIS') || '|' ||
        coalesce(p_tenant_id::text, '') || '|' ||
        coalesce(p_campus_id::text, '') || '|' ||
        p_occurred_at::text || '|' ||
        coalesce(p_actor_user_id::text, '') || '|' ||
        coalesce(p_actor_role, '') || '|' ||
        coalesce(p_action, '') || '|' ||
        coalesce(p_table_name, '') || '|' ||
        coalesce(p_row_id::text, '') || '|' ||
        coalesce(p_before::text, '') || '|' ||
        coalesce(p_after::text, '') || '|' ||
        coalesce(array_to_string(p_changed_columns, ','), ''),
        'UTF8'
      )
    ),
    'hex'
  );
$$;

revoke execute on function app.fn_audit_row_hash(
  text, uuid, uuid, timestamptz, uuid, text, text, text, uuid, jsonb, jsonb, text[]
) from public, anon, authenticated;

-- Body otherwise unchanged from student_medical.sql's version (the actual
-- latest redefinition before this migration — audit_log_hardening.sql's
-- own version was itself already superseded there; confirmed by grepping
-- every migration for `create or replace function app.tg_audit_row`
-- before writing anything here, per this FR's own brief). That version's
-- "a row with no derivable tenant_id (fee_plan_line has no tenant_id
-- column at all; role's global templates have tenant_id NULL by design)
-- skips logging instead of violating audit_log's own NOT NULL constraint"
-- guard is preserved verbatim below, evaluated before any hash-chain work
-- begins — a skipped row was never going into the chain either way, so
-- this isn't a new gap, and skipping it before touching the advisory lock
-- means a table that's exempt from auditing never contends the lock at all.
-- Additions on top of that version are: v_campus_id (mirrors the tenant_id
-- derivation, including the "table has no such column, fall back to its
-- own id" case for the campus table itself),
-- clock_timestamp() instead of the column's now()-default (a transaction
-- that writes several audited rows — generate_challans' per-enrolment
-- loop, soft_delete's cascade into enrolment/fee_challan — must not give
-- them all the identical transaction-start timestamp; same fix, same
-- reasoning as 20260731140000_student_created_at_clock_timestamp.sql,
-- applied here for the hash chain's own ordering rather than a UI sort),
-- and the hash chain itself. A pg_advisory_xact_lock keyed per tenant
-- serializes concurrent transactions' "read the previous row_hash, compute
-- mine, insert" sequence so two overlapping writers for the same tenant
-- can never both read the same "latest" hash and silently fork the chain;
-- within a single transaction that writes multiple rows the lock is a
-- same-session no-op (Postgres advisory locks are re-entrant per session)
-- and each row still sees the previous row's own uncommitted insert, so
-- the chain stays linear either way.
--
-- Chain scope is per tenant, not one global sequence: every other
-- ordering/index in this table (audit_log_tenant_idx) and every RLS policy
-- on it is already tenant-scoped, an Owner only ever verifies their own
-- tenant, and a single global chain would serialize unrelated tenants'
-- writes against each other for no benefit.
create or replace function app.tg_audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid;
  v_campus_id   uuid;
  v_row_id      uuid;
  v_changed     text[];
  v_before      jsonb;
  v_after       jsonb;
  v_redacted    text[];
  v_actor_role  public.app_role;
  v_occurred_at timestamptz;
  v_prev_hash   text;
  v_row_hash    text;
begin
  v_tenant_id := coalesce(
    (to_jsonb(new)->>'tenant_id')::uuid,
    (to_jsonb(old)->>'tenant_id')::uuid,
    -- tenant itself has no tenant_id column — its own id is the scope.
    case when tg_table_name = 'tenant' then coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid) end
  );

  -- A row that is legitimately tenant-less (e.g. a global role template,
  -- tenant_id IS NULL by design) or lives on a table with no tenant_id
  -- column at all (fee_plan_line) has nothing to attribute a tenant-scoped
  -- audit row — or a tenant-scoped hash chain — to. Skip logging rather
  -- than violate audit_log's NOT NULL constraint; this is student_medical.sql's
  -- own guard, unchanged.
  if v_tenant_id is null and tg_table_name <> 'tenant' then
    return coalesce(new, old);
  end if;

  v_campus_id := coalesce(
    (to_jsonb(new)->>'campus_id')::uuid,
    (to_jsonb(old)->>'campus_id')::uuid,
    -- campus itself has no campus_id column — its own id is the scope.
    case when tg_table_name = 'campus' then coalesce((to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid) end
  );
  -- app_user's primary key is user_id, not id — fall back to it generically
  -- rather than special-casing the table name.
  v_row_id := coalesce(
    (to_jsonb(new)->>'id')::uuid, (to_jsonb(old)->>'id')::uuid,
    (to_jsonb(new)->>'user_id')::uuid, (to_jsonb(old)->>'user_id')::uuid
  );

  if tg_op = 'UPDATE' then
    select array_agg(key) into v_changed
      from jsonb_each(to_jsonb(new))
     where to_jsonb(new)->key is distinct from to_jsonb(old)->key;
  end if;

  select array_agg(column_name) into v_redacted
    from public.audit_redacted_column where table_name = tg_table_name;

  v_before := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) else null end;
  v_after  := case when tg_op in ('UPDATE', 'INSERT') then to_jsonb(new) else null end;

  if v_redacted is not null then
    if v_before is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_before from jsonb_each(v_before) as t(k, v);
    end if;
    if v_after is not null then
      select jsonb_object_agg(t.k, case when t.k = any(v_redacted) then to_jsonb('[redacted]'::text) else t.v end)
        into v_after from jsonb_each(v_after) as t(k, v);
    end if;
  end if;

  v_actor_role := nullif(app.auth_role(), 'none')::public.app_role;

  perform pg_advisory_xact_lock(hashtextextended('audit-chain:' || coalesce(v_tenant_id::text, 'GLOBAL'), 0));

  v_occurred_at := clock_timestamp();

  select row_hash into v_prev_hash
    from public.audit_log
   where tenant_id = v_tenant_id
   order by occurred_at desc, id desc
   limit 1;

  v_row_hash := app.fn_audit_row_hash(
    v_prev_hash, v_tenant_id, v_campus_id, v_occurred_at,
    (select auth.uid()), v_actor_role::text, lower(tg_op), tg_table_name, v_row_id,
    v_before, v_after, v_changed
  );

  insert into public.audit_log (
    tenant_id, campus_id, occurred_at, actor_user_id, actor_role, action, table_name, row_id,
    before, after, changed_columns, prev_hash, row_hash
  ) values (
    v_tenant_id, v_campus_id, v_occurred_at, (select auth.uid()), v_actor_role,
    lower(tg_op)::public.audit_action, tg_table_name, v_row_id,
    v_before, v_after, v_changed, v_prev_hash, v_row_hash
  );

  return coalesce(new, old);
end;
$$;

-- ── AC3: campus-scoped read RLS ──────────────────────────────────────────
-- Principal is now restricted to their own app.auth_campus_ids() for rows
-- that actually carry a campus_id. Rows with campus_id null stay visible
-- to Principal too — audit_log spans both campus-scoped tables (student,
-- fee_challan, enrolment, ...) and genuinely tenant-wide catalogue tables
-- with no campus concept at all (class_level, fee_head, subjects, role,
-- ...); campus_id null on one of those isn't "some other campus's data",
-- it's "this entity has no campus", and a Principal who can already read
-- and edit class_level directly (create_class_level's own role check
-- includes principal) can already see the SAME before/after values there
-- — auditing it more strictly than the live table itself would achieve
-- nothing. class_levels.test.sql's own pre-existing assertion ("the
-- ordinal swap produced an audit row for the class level it touched",
-- read back as Principal, no explicit role reset) is exactly this case —
-- confirmed by running it in isolation before settling on this shape:
-- excluding campus_id-null rows outright made that pre-existing,
-- unrelated test fail. AC3 itself only ever exercises a real,
-- non-null p_campus_id (fee_challan, in the FR's own example), which this
-- policy still filters correctly — `campus_id = any(app.auth_campus_ids())`
-- is false, not null, whenever campus_id is a real, out-of-scope campus.
drop policy audit_log_tenant_scope on public.audit_log;

create policy audit_log_tenant_scope on public.audit_log
  for select to authenticated
  using (
    app.auth_role() in ('owner', 'principal', 'super_admin')
    and tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id is null or campus_id = any(app.auth_campus_ids()))
  );

-- ═══════════════════════════════════════════════════════════════════════
-- 2. Chain verification: result table + the nightly job function
-- ═══════════════════════════════════════════════════════════════════════

create type public.audit_chain_status as enum ('ok', 'broken');

create table public.audit_chain_verification (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  run_at             timestamptz not null default clock_timestamp(),
  status             public.audit_chain_status not null,
  rows_checked       bigint not null default 0,
  broken_audit_log_id uuid,
  broken_occurred_at timestamptz,
  broken_reason      text
);

create index idx_audit_chain_verification_tenant on public.audit_chain_verification (tenant_id, run_at desc);

alter table public.audit_chain_verification enable row level security;

create policy audit_chain_verification_owner_read on public.audit_chain_verification
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner'));

-- Only ever inserted by run_audit_chain_verification() itself (SECURITY
-- DEFINER) — same hard-write-denial posture as audit_log and purge_hold.
revoke insert, update, delete on public.audit_chain_verification from authenticated, anon;

-- AC2: walks each tenant's chain in (occurred_at, id) order, recomputing
-- the expected hash from each row's own stored fields via the same
-- app.fn_audit_row_hash() the trigger uses, and separately re-deriving
-- what prev_hash SHOULD be from the actual previous row — so both a
-- content edit (before/after/table_name/... changed, row_hash now
-- inconsistent with its own fields) and a structural edit (a row deleted
-- or reordered, breaking someone else's prev_hash linkage) are caught.
-- Stops at the first break per tenant and records its audit_log row id +
-- occurred_at, exactly what AC2 asks for. Same null-safe, un-scheduled
-- "real function a cron WOULD call" convention as
-- purge_soft_deleted_records/dispatch_absentee_notifications: an
-- authenticated caller (owner/super_admin only) is pinned to their own
-- tenant regardless of p_tenant_id; a service_role/no-JWT caller may scan
-- one tenant or (p_tenant_id null) every tenant.
create or replace function public.run_audit_chain_verification(p_tenant_id uuid default null)
returns setof public.audit_chain_verification
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_tenant uuid := app.auth_tenant_id();
  v_tenant        record;
  v_row           record;
  v_prev_hash     text;
  v_expected_hash text;
  v_checked       bigint;
  v_broken        boolean;
  v_result        public.audit_chain_verification%rowtype;
begin
  if v_caller_tenant is not null then
    if app.auth_role() not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    p_tenant_id := v_caller_tenant;
  end if;

  for v_tenant in
    select id from public.tenant where p_tenant_id is null or id = p_tenant_id order by id
  loop
    v_prev_hash := null;
    v_checked := 0;
    v_broken := false;

    for v_row in
      select id, campus_id, occurred_at, actor_user_id, actor_role, action, table_name, row_id,
             before, after, changed_columns, prev_hash, row_hash
        from public.audit_log
       where tenant_id = v_tenant.id
       order by occurred_at, id
    loop
      v_expected_hash := app.fn_audit_row_hash(
        v_prev_hash, v_tenant.id, v_row.campus_id, v_row.occurred_at,
        v_row.actor_user_id, v_row.actor_role::text, v_row.action::text, v_row.table_name, v_row.row_id,
        v_row.before, v_row.after, v_row.changed_columns
      );

      if v_row.prev_hash is distinct from v_prev_hash or v_row.row_hash is distinct from v_expected_hash then
        insert into public.audit_chain_verification (
          tenant_id, status, rows_checked, broken_audit_log_id, broken_occurred_at, broken_reason
        ) values (
          v_tenant.id, 'broken', v_checked + 1, v_row.id, v_row.occurred_at,
          case
            when v_row.prev_hash is distinct from v_prev_hash then 'prev_hash does not match the preceding row''s row_hash'
            else 'row_hash does not match this row''s own stored fields'
          end
        ) returning * into v_result;
        v_broken := true;
        return next v_result;
        exit;
      end if;

      v_prev_hash := v_row.row_hash;
      v_checked := v_checked + 1;
    end loop;

    if not v_broken then
      insert into public.audit_chain_verification (tenant_id, status, rows_checked)
      values (v_tenant.id, 'ok', v_checked)
      returning * into v_result;
      return next v_result;
    end if;
  end loop;

  return;
end;
$$;

revoke execute on function public.run_audit_chain_verification(uuid) from public, anon;
grant execute on function public.run_audit_chain_verification(uuid) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- 3. Export job: table, self-audit trigger, request/complete/fail RPCs
-- ═══════════════════════════════════════════════════════════════════════

create type public.audit_export_status as enum ('queued', 'running', 'completed', 'failed');

create table public.audit_export_job (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  requested_by        uuid references public.app_user(user_id),
  from_date           date not null,
  to_date             date not null,
  table_names         text[] not null,
  campus_id           uuid references public.campus(id),
  status              public.audit_export_status not null default 'queued',
  row_count           bigint,
  manifest            jsonb,
  storage_prefix      text,
  download_url        text,
  download_expires_at timestamptz,
  error               text,
  requested_at        timestamptz not null default clock_timestamp(),
  completed_at        timestamptz,
  check (to_date >= from_date),
  check (array_length(table_names, 1) > 0)
);

create index idx_audit_export_job_tenant on public.audit_export_job (tenant_id, requested_at desc);

-- AC1: "audit_log itself records the export with actor and filter
-- parameters" — audit_export_job is just another audited table.
-- requested_by/from_date/to_date/table_names/campus_id all land in the
-- INSERT row's `after` jsonb for free; the completion (row_count,
-- download_url, ...) lands as an `update` row the same way. No bespoke
-- "log the export" code needed.
create trigger audit_export_job_audit after insert or update on public.audit_export_job
  for each row execute function app.tg_audit_row();

alter table public.audit_export_job enable row level security;

create policy audit_export_job_read on public.audit_export_job
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or requested_by = auth.uid())
  );

-- Same hard-write-denial posture as audit_log/audit_chain_verification —
-- only the SECURITY DEFINER functions below (running as their owner) can
-- write here.
revoke insert, update, delete on public.audit_export_job from authenticated, anon;

create or replace function public.request_audit_export(
  p_from date, p_to date, p_table_names text[], p_campus_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_to < p_from then
    raise exception 'INVALID_DATE_RANGE' using errcode = '22023';
  end if;
  if p_table_names is null or array_length(p_table_names, 1) is null then
    raise exception 'NO_ENTITIES_SELECTED' using errcode = '22023';
  end if;
  -- AC3: a campus outside the caller's own JWT scope is deliberately NOT
  -- rejected here — this function only gates on role and that the campus
  -- exists in the caller's own tenant. The actual campus-scope enforcement
  -- happens exactly where AC3 says it must: as an RLS filter on the real
  -- data read (a plain SELECT against audit_log, from the requester's own
  -- session — see apps/academy/app/(app)/audit-export/actions.ts), so a
  -- Principal requesting a foreign campus gets a real job that completes
  -- with row_count 0, not a FORBIDDEN error here.
  if p_campus_id is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.audit_export_job (tenant_id, requested_by, from_date, to_date, table_names, campus_id, status)
  values (app.auth_tenant_id(), auth.uid(), p_from, p_to, p_table_names, p_campus_id, 'queued')
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke execute on function public.request_audit_export(date, date, text[], uuid) from public, anon;
grant execute on function public.request_audit_export(date, date, text[], uuid) to authenticated;

create or replace function public.complete_audit_export(
  p_job_id uuid, p_row_count bigint, p_manifest jsonb, p_storage_prefix text, p_download_url text, p_expires_hours int default 24
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.audit_export_job%rowtype;
begin
  select * into v_job from public.audit_export_job where id = p_job_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_job.requested_by is distinct from auth.uid() and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.audit_export_job
     set status = 'completed',
         row_count = p_row_count,
         manifest = p_manifest,
         storage_prefix = p_storage_prefix,
         download_url = p_download_url,
         download_expires_at = clock_timestamp() + make_interval(hours => p_expires_hours),
         completed_at = clock_timestamp()
   where id = p_job_id;
end;
$$;

revoke execute on function public.complete_audit_export(uuid, bigint, jsonb, text, text, int) from public, anon;
grant execute on function public.complete_audit_export(uuid, bigint, jsonb, text, text, int) to authenticated;

create or replace function public.fail_audit_export(p_job_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.audit_export_job%rowtype;
begin
  select * into v_job from public.audit_export_job where id = p_job_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_job.requested_by is distinct from auth.uid() and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.audit_export_job set status = 'failed', error = p_error, completed_at = clock_timestamp() where id = p_job_id;
end;
$$;

revoke execute on function public.fail_audit_export(uuid, text) from public, anon;
grant execute on function public.fail_audit_export(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- 4. Storage: private bucket, RLS scoped by {tenant_id}/{job_id}/... path
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('audit-exports', 'audit-exports', false, 209715200, array['application/json', 'application/x-ndjson', 'text/plain'])
on conflict (id) do nothing;

-- Same shape as FR-A18's branding_insert_owner/branding_read_tenant, but
-- keyed off the storage path's own tenant_id segment (set by the uploader
-- itself — apps/academy/app/(app)/audit-export/actions.ts writes to
-- `{tenant_id}/{job_id}/...`) rather than a lookup table, since there's no
-- per-object metadata row (branding_asset's equivalent) for export files.
create policy audit_export_insert_owner on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'audit-exports'
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (storage.foldername(name))[1] = app.auth_tenant_id()::text
  );

create policy audit_export_read_owner on storage.objects
  for select to authenticated
  using (
    bucket_id = 'audit-exports'
    and (storage.foldername(name))[1] = app.auth_tenant_id()::text
    and (
      app.auth_role() in ('super_admin', 'owner')
      or exists (
        select 1 from public.audit_export_job j
         where j.tenant_id = app.auth_tenant_id()
           and j.requested_by = auth.uid()
           and (storage.foldername(name))[2] = j.id::text
      )
    )
  );
