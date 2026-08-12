-- FR-T02: gapless certificate serial allocation.
--
-- "As a Principal, I want every certificate serial number to be unique,
-- sequential and gapless within my campus and academic year, so that the
-- register I hand to a school inspector cannot be accused of having
-- numbers torn out."
--
-- Second of module T's certificates cluster. FR-T01
-- (20260731860000_certificate_template_designer.sql) already declares
-- 'issue.serial_no' as a REQUIRED merge field on transfer templates and
-- left it as an unresolved placeholder pending this migration; a TC
-- authored yesterday prints a real serial the moment FR-T03 can issue one.
--
-- ── NOT a sequence, and that is the whole feature ──────────────────────
--
-- nextval() is deliberately non-transactional: it advances even when the
-- calling transaction aborts, precisely so concurrent writers never block
-- each other. That trade is correct for a surrogate key and catastrophic
-- for a statutory register — a clerk whose PDF render fails after
-- allocation would burn number 00148 forever, and the inspector reads the
-- hole as a certificate that was issued and then torn out. Same reasoning
-- as gr_sequence (FR-C01), employee codes (FR-D01) and challan_counter
-- (FR-K10), all of which are ordinary counter ROWS for the same reason.
--
-- The counter therefore lives in a table and is advanced by an ordinary
-- UPDATE inside the caller's transaction, which buys AC2 for free: the
-- increment is transactional state, so a ROLLBACK — of the whole
-- transaction or of a plpgsql BEGIN…EXCEPTION subtransaction, which is
-- what an "issue failed at PDF generation" handler actually is — takes the
-- increment with it and the next caller is handed the same number again.
--
-- ── AC1: gaplessness under concurrency needs serialization ─────────────
--
-- Twenty clerks pressing Issue at the same instant cannot all be handed a
-- number optimistically and reconciled afterwards: any retry-on-conflict
-- scheme lets a loser's transaction abort *after* it has consumed a value,
-- which is the gap this FR exists to prevent. So allocation serialises, by
-- design, on pg_advisory_xact_lock keyed on (campus, type, session) — the
-- same idiom used throughout this schema for "one writer at a time on this
-- logical row". Two properties matter and both are load-bearing:
--
--   * it is the XACT variant, released automatically at COMMIT *and* at
--     ROLLBACK. The session-scoped pg_advisory_lock() would survive the
--     rollback and, on PostgREST's pooled connections, leak the lock into
--     an unrelated later request and deadlock the whole campus;
--   * it is taken BEFORE the insert-if-absent, so the very first
--     allocation of a series cannot race two rows into existence.
--
-- The lock is held only for the microseconds between the UPDATE and the
-- caller's COMMIT. Serialising a few thousand certificates a year costs
-- nothing; the register being provably intact is the product.
--
-- ── Why it is not granted to authenticated ─────────────────────────────
--
-- A clerk who could call this directly could allocate a number and commit
-- without ever writing a certificate behind it — a committed, unused
-- serial, which is exactly the gap the user story forbids. Allocation is
-- only safe in the same transaction as the issue row, so the function is
-- service_role-grantable infrastructure (same posture as
-- next_challan_no()) and FR-T03's issue_transfer_certificate(), itself
-- SECURITY DEFINER, will call it inline. Nothing in the UI calls it.
--
-- ── AC4: blocking a human without blocking the allocator ───────────────
--
-- The stated threat is a Super Admin with SQL access, so "the app never
-- writes an UPDATE" is not a control. Three layers, in the order an
-- attacker meets them:
--
--   1. RLS. `authenticated` — every application role including super_admin,
--      since they all reach the database as the same Postgres role — has a
--      SELECT policy and no write policy at all, plus the explicit
--      serial_counter_no_direct_dml (USING false) so the intent is
--      greppable. A direct UPDATE through PostgREST or psql matches zero
--      rows and changes nothing.
--   2. trg_block_manual_counter_edit. service_role has BYPASSRLS and full
--      DML grants, so RLS is not the last word; the trigger is. It fires
--      on INSERT, UPDATE and DELETE regardless of caller and raises
--      'serial counters are append-only via allocate_certificate_serial()'.
--   3. The trigger's allow-list is deliberately narrow. An UPDATE passes
--      only when ALL of:
--        * current_user is the table's owner — i.e. the executing context
--          is a SECURITY DEFINER function running as the owner, not a
--          logged-in role. The trigger is SECURITY INVOKER precisely so
--          current_user still reports the caller;
--        * the plpgsql call stack (GET DIAGNOSTICS … PG_CONTEXT) contains a
--          frame for public.allocate_certificate_serial. Neither
--          authenticated nor service_role holds CREATE on public or app, so
--          neither can plant a same-named function to forge the frame;
--        * the change is exactly +1 on current_value with every other
--          column byte-identical. Even a forged frame could then only do
--          what allocation itself does — advance by one — and could never
--          rewind the counter, jump it, or repoint the series.
--      INSERT is allowed only at current_value = 0, which makes "a series
--      always starts at 1" (AC3) structural rather than conventional, and
--      DELETE is refused outright: dropping a counter row would restart a
--      series and reissue numbers that are already on paper. The refusal
--      covers a CASCADE from the campus or session too, so a campus that
--      has issued a certificate can no longer be hard-deleted — the same
--      posture fee_ledger's no-mutate trigger already takes, and nothing
--      is lost by it: no application role holds a DELETE policy on campus
--      or academic_session to begin with.
--
-- A database superuser can always drop a trigger; that is outside the
-- threat model and outside what any schema can defend. What is defended is
-- every role this application actually authenticates as.
--
-- ── The academic year is the academic SESSION (AC3) ────────────────────
--
-- This schema already has exactly one concept of a year — public
-- .academic_session, which provision_tenant() creates named 'YYYY-YY'
-- running 1 Jan to 31 Dec — and challan_counter, application_no_counter
-- and enquiry_no_counter all key on session_id. Inventing a parallel
-- integer year would immediately disagree with them. So the counter is
-- keyed on session_id and the serial's YEAR SEGMENT is
-- extract(year from academic_session.starts_on), frozen onto the counter
-- row as academic_year when the series is created. Rolling into session
-- '2027-28' therefore creates a fresh counter row, which starts at 1 and
-- renders 2027 — AC3, with no reset job to forget to run.
--
-- academic_year is additionally UNIQUE per (campus, type). Two sessions
-- beginning in the same calendar year would otherwise own two counters
-- that both render 'TC-2027-000001' — a duplicate serial, which is the
-- other half of AC1's guarantee.
--
-- ── Scope cuts / notes for the rest of the cluster ─────────────────────
--
--   * No allocation LEDGER table. FR-T01's header already names
--     certificate_issue (FR-T03) as the bound register FR-T08 makes
--     append-only; a second table listing allocated serials would be a
--     competing register, and the two would eventually disagree. The
--     counter is the allocator's own state, not the register.
--   * prefix_pattern is chosen per certificate type when the series is
--     created and frozen for its life (the trigger refuses to change it).
--     Per-school pattern configuration is deliberately not built: changing
--     the format halfway through a year is how a register stops looking
--     like one. Whenever an FR does want it, it needs a SECURITY DEFINER
--     setter restricted to current_value = 0 and an extra frame in the
--     trigger's allow-list — not a relaxation of the +1 rule.
--   * FR-T05's character certificates get an INDEPENDENT series for free:
--     certificate_type is part of the key, so 'character' has its own
--     counter, its own 'CC-' pattern and its own 1..n run.
--   * FR-T08's cancellation must NEVER rewind the counter. A cancelled
--     certificate keeps its serial and stays in the register with a
--     cancelled status cross-referencing its replacement; handing the
--     number back is what would create the gap.
--   * FR-T03 should call allocate_certificate_serial() from inside
--     issue_transfer_certificate() and store the returned text on
--     certificate_issue.serial_no, in the same transaction as the PDF
--     render, so a render failure returns the number.
--
-- Every function below has its full signature fixed. Adding a defaulted
-- argument with CREATE OR REPLACE creates a DISTINCT overload and makes
-- existing calls ambiguous (FR-G05 hit exactly this) — drop and recreate,
-- and re-issue the grants.

-- ═══════════════════════════════════════════════════════════════════════
-- The counter
-- ═══════════════════════════════════════════════════════════════════════

create table public.certificate_serial_counter (
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  certificate_type  public.certificate_type not null,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  -- Frozen at creation from academic_session.starts_on; the serial's year
  -- segment must not move if a session's dates are later corrected.
  academic_year     int not null check (academic_year between 1900 and 2999),
  prefix_pattern    text not null,
  seq_width         int not null default 6 check (seq_width between 3 and 12),
  current_value     bigint not null default 0 check (current_value >= 0),
  last_allocated_at timestamptz,
  last_allocated_by uuid references public.app_user(user_id),
  created_at        timestamptz not null default clock_timestamp(),
  primary key (campus_id, certificate_type, session_id),
  constraint chk_serial_pattern_shape check (prefix_pattern ~ '^[A-Za-z0-9{}/_.-]{3,40}$'),
  constraint chk_serial_pattern_has_seq check (prefix_pattern like '%{SEQ}%')
);

-- Two counters that would render the same year segment for the same campus
-- and type are a duplicate-serial generator; there can only be one.
create unique index uq_serial_counter_year
  on public.certificate_serial_counter (campus_id, certificate_type, academic_year);

create index idx_serial_counter_tenant on public.certificate_serial_counter (tenant_id, campus_id);

-- ═══════════════════════════════════════════════════════════════════════
-- Rendering a serial
-- ═══════════════════════════════════════════════════════════════════════

-- 'TC-2026-000148'. FR-T01's field catalogue already previews
-- issue.serial_no in exactly this shape.
create or replace function app.certificate_serial_default_pattern(p_certificate_type public.certificate_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_certificate_type
           when 'transfer'  then 'TC-{YEAR}-{SEQ}'
           when 'character' then 'CC-{YEAR}-{SEQ}'
           else                  'BC-{YEAR}-{SEQ}'
         end;
$$;

revoke execute on function app.certificate_serial_default_pattern(public.certificate_type)
  from public, anon, authenticated;

-- {CAMPUS} exists because the uniqueness the story asks for is per campus:
-- two campuses of one tenant legitimately both hold serial 000148, and a
-- district office looking at both wants to tell them apart.
create or replace function public.format_certificate_serial(
  p_pattern text,
  p_academic_year int,
  p_seq bigint,
  p_seq_width int,
  p_campus_code text
)
returns text
language sql
immutable
set search_path = ''
as $$
  select replace(
           replace(
             replace(p_pattern, '{YEAR}', p_academic_year::text),
             '{CAMPUS}', coalesce(p_campus_code, '')
           ),
           '{SEQ}', lpad(p_seq::text, p_seq_width, '0')
         );
$$;

revoke execute on function public.format_certificate_serial(text, int, bigint, int, text) from public, anon;
grant execute on function public.format_certificate_serial(text, int, bigint, int, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the counter is append-only
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_block_manual_counter_edit()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
begin
  if tg_op = 'DELETE' then
    raise exception 'serial counters are append-only via allocate_certificate_serial()'
      using errcode = '42501',
            detail = format('delete of counter campus=%s type=%s session=%s at %s',
                            old.campus_id, old.certificate_type, old.session_id, old.current_value),
            hint = 'Deleting a counter restarts its series and reissues numbers that are already on paper.';
  end if;

  if tg_op = 'INSERT' then
    -- A new series always starts at zero and is walked up one at a time;
    -- that is what makes AC3's "resets to 00001" structural.
    if new.current_value <> 0 or new.last_allocated_at is not null then
      raise exception 'serial counters are append-only via allocate_certificate_serial()'
        using errcode = '42501',
              detail = format('series seeded at %s', new.current_value),
              hint = 'A certificate series must start at zero and be advanced one certificate at a time.';
    end if;
    return new;
  end if;

  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  if current_user = v_owner
     and v_stack ~ 'function public\.allocate_certificate_serial\('
     and new.current_value = old.current_value + 1
     and new.tenant_id        is not distinct from old.tenant_id
     and new.campus_id        is not distinct from old.campus_id
     and new.certificate_type is not distinct from old.certificate_type
     and new.session_id       is not distinct from old.session_id
     and new.academic_year    is not distinct from old.academic_year
     and new.prefix_pattern   is not distinct from old.prefix_pattern
     and new.seq_width        is not distinct from old.seq_width
     and new.created_at       is not distinct from old.created_at
  then
    return new;
  end if;

  raise exception 'serial counters are append-only via allocate_certificate_serial()'
    using errcode = '42501',
          detail = format('attempted %s -> %s by %s', old.current_value, new.current_value, current_user),
          hint = 'Serials are allocated one at a time, inside the transaction that issues the certificate.';
end;
$$;

create trigger trg_block_manual_counter_edit
  before insert or update or delete on public.certificate_serial_counter
  for each row execute function app.tg_block_manual_counter_edit();

create trigger certificate_serial_counter_audit
  after insert or update or delete on public.certificate_serial_counter
  for each row execute function app.tg_audit_row();

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.certificate_serial_counter enable row level security;

-- The register's own administrators can watch the counters; nobody else
-- needs to know how many certificates a campus has issued.
create policy serial_counter_read on public.certificate_serial_counter
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- There is no write policy, so writes are already denied by default; this
-- states it, so a reader does not have to infer a security property from
-- an absence. INSERT and DELETE are likewise policy-less and denied.
create policy serial_counter_no_direct_dml on public.certificate_serial_counter
  for update to authenticated
  using (false)
  with check (false);

-- ═══════════════════════════════════════════════════════════════════════
-- Allocation — AC1, AC2, AC3
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.allocate_certificate_serial(
  p_campus_id uuid,
  p_certificate_type public.certificate_type,
  p_session_id uuid default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid;
  v_campus_code text;
  v_session_id  uuid;
  v_starts_on   date;
  v_year        int;
  v_seq         bigint;
  v_pattern     text;
  v_width       int;
begin
  select c.tenant_id, c.code into v_tenant_id, v_campus_code
    from public.campus c
   where c.id = p_campus_id;
  if v_tenant_id is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Callers with a JWT are held to their tenant and campus scope
  -- (b16ba25's convention). A caller with no claims is service_role or a
  -- SECURITY DEFINER function upstream of one, which has already made its
  -- own decision about who may issue.
  if app.auth_tenant_id() is not null then
    if app.auth_tenant_id() <> v_tenant_id then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('super_admin', 'owner')
       and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  if p_session_id is null then
    select s.id, s.starts_on into v_session_id, v_starts_on
      from public.academic_session s
     where s.tenant_id = v_tenant_id
       and s.is_current
       and (s.campus_id = p_campus_id or s.campus_id is null)
     order by (s.campus_id is not null) desc
     limit 1;
  else
    select s.id, s.starts_on into v_session_id, v_starts_on
      from public.academic_session s
     where s.id = p_session_id
       and s.tenant_id = v_tenant_id
       and (s.campus_id = p_campus_id or s.campus_id is null);
  end if;
  if v_session_id is null then
    raise exception 'ACADEMIC_SESSION_NOT_FOUND'
      using errcode = 'P0002',
            hint = 'A certificate serial belongs to an academic session; the campus has no current one.';
  end if;
  v_year := extract(year from v_starts_on)::int;

  -- AC1. One allocator at a time per series, for the whole of the calling
  -- transaction. XACT-scoped: COMMIT and ROLLBACK both release it, which
  -- is what makes AC2's failed issue safe to retry immediately.
  perform pg_advisory_xact_lock(hashtextextended(
    'cert-serial:' || p_campus_id::text || ':' || p_certificate_type::text || ':' || v_session_id::text, 0));

  insert into public.certificate_serial_counter (
    tenant_id, campus_id, certificate_type, session_id, academic_year, prefix_pattern
  ) values (
    v_tenant_id, p_campus_id, p_certificate_type, v_session_id, v_year,
    app.certificate_serial_default_pattern(p_certificate_type)
  )
  on conflict (campus_id, certificate_type, session_id) do nothing;

  -- AC2. An ordinary transactional UPDATE, never nextval(): the increment
  -- lives and dies with this transaction, so a failure after this line
  -- hands the number straight back.
  update public.certificate_serial_counter
     set current_value     = current_value + 1,
         last_allocated_at = clock_timestamp(),
         last_allocated_by = (select auth.uid())
   where campus_id = p_campus_id
     and certificate_type = p_certificate_type
     and session_id = v_session_id
  returning current_value, prefix_pattern, seq_width, academic_year
       into v_seq, v_pattern, v_width, v_year;

  return public.format_certificate_serial(v_pattern, v_year, v_seq, v_width, v_campus_code);
end;
$$;

revoke execute on function public.allocate_certificate_serial(uuid, public.certificate_type, uuid)
  from public, anon, authenticated;
grant execute on function public.allocate_certificate_serial(uuid, public.certificate_type, uuid)
  to service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- What the register administrator sees
-- ═══════════════════════════════════════════════════════════════════════

-- Read-only, and readable exactly by whoever serial_counter_read lets
-- through — security_invoker keeps the base table's RLS in force.
create or replace view public.v_certificate_serial_register
with (security_invoker = true) as
select
  ctr.tenant_id,
  ctr.campus_id,
  c.code as campus_code,
  c.name as campus_name,
  ctr.certificate_type,
  ctr.session_id,
  s.name as session_name,
  ctr.academic_year,
  ctr.prefix_pattern,
  ctr.seq_width,
  ctr.current_value,
  case when ctr.current_value > 0
       then public.format_certificate_serial(ctr.prefix_pattern, ctr.academic_year, ctr.current_value, ctr.seq_width, c.code)
  end as last_serial,
  public.format_certificate_serial(ctr.prefix_pattern, ctr.academic_year, ctr.current_value + 1, ctr.seq_width, c.code) as next_serial,
  ctr.last_allocated_at,
  ctr.last_allocated_by
from public.certificate_serial_counter ctr
join public.campus c on c.id = ctr.campus_id
join public.academic_session s on s.id = ctr.session_id;

revoke all on public.v_certificate_serial_register from public, anon;
grant select on public.v_certificate_serial_register to authenticated;
