-- FR-L11: expense voucher approval chain.
--
-- "As a Principal, I want expense vouchers above a threshold to reach me
-- for approval before payment, so that no significant spend leaves the
-- campus without my sign-off."
--
-- First migration of module L (Payroll & Expenses). Nothing of this module
-- existed before it — grepped for expense/voucher/payroll across every
-- migration and found nothing — so the minimum module L needs to exist is
-- created here and nowhere more than that.
--
-- ── Money is paisa as bigint, not numeric ──────────────────────────────
--
-- The FR's suggested schema says `amount numeric`. This codebase does not
-- do that anywhere: fee_ledger.amount_paisa, fee_challan.net_paisa,
-- fee_payment.amount_paisa and every figure module K carries are bigint
-- paisa, and FR-K24's own ACs are written in paisa (850000 paisa = PKR
-- 8,500). A second money representation in the same schema is how two
-- screens end up disagreeing about the same rupee, so expense_voucher
-- follows the house convention and AC1's thresholds are stored in paisa:
--
--   PKR      25,000  =  2,500,000 paisa   (top of self-approval)
--   PKR     200,000  = 20,000,000 paisa   (top of the Principal band)
--
-- ── AC1: routing, and "CANNOT be marked paid" ──────────────────────────
--
-- approval_threshold holds contiguous bands per campus, in paisa, with an
-- EXCLUDE constraint so two bands can never claim the same rupee.
-- required_role NULL means the band needs no one above the submitter —
-- app_role has no 'self' value and ALTER TYPE ... ADD VALUE cannot share a
-- migration with a statement that uses the new label, so NULL carries that
-- meaning rather than a new enum member. Every campus is seeded with the
-- three bands AC1 names by an AFTER INSERT trigger on campus rather than
-- from provision_tenant, because campuses are created from two paths
-- (provision_tenant and create_campus) and a trigger covers both, and every
-- path added later, without either being re-emitted.
--
-- "Cannot be marked paid" is enforced in the database, three times over,
-- because a control that lives in a React component is not a control:
--
--   1. There is no UPDATE path onto expense_voucher for an application
--      role. mark_expense_voucher_paid() is the only writer of status
--      'paid'.
--   2. trg_expense_voucher_status_guard fires BEFORE UPDATE FOR EACH ROW
--      regardless of caller and refuses 'paid' unless the row is
--      'approved' AND an approval row of sufficient rank already exists in
--      expense_voucher_approval. The check is against the trail, not
--      against the voucher's own status column, so forcing status through
--      an intermediate value buys nothing.
--   3. expense_voucher_update_denied (WITH CHECK false) would reject the
--      row version even with the trigger dropped.
--
-- ── AC2: rejection ─────────────────────────────────────────────────────
--
-- The >= 10 character reason is a CHECK constraint on the approval row
-- (chk_expense_approval_reason) as well as a named error in
-- decide_expense_voucher(), so a reason cannot be short by any path.
-- 'rejected' is terminal: the status guard refuses every update whose OLD
-- status is 'rejected', which makes the voucher non-payable and
-- non-editable in the same clause. Correcting a rejected voucher means
-- submitting a new one, exactly as the AC says.
--
-- Content columns are frozen from INSERT for EVERY status, not only
-- 'rejected'. The AC only requires it of a rejected voucher, but an
-- approved PKR 150,000 voucher whose amount could still be edited to PKR
-- 500,000 would make the Principal's sign-off meaningless, so the freeze is
-- unconditional and a rejected voucher is simply the case where nothing at
-- all may move.
--
-- ── AC3: the threshold split, and what "same payee" can honestly mean ───
--
-- There is no payee/vendor entity in this schema and this FR does not
-- invent one (FR-L10 is the module's master-data FR). Matching on the raw
-- payee_name string is fragile — "M/s Ali Traders" and "m/s  ali traders."
-- are the same shop — so every voucher carries payee_key, written at
-- INSERT by app.fn_expense_payee_key():
--
--   * an NTN, if given, reduced to its digits. A National Tax Number is a
--     real identity and beats any amount of string cleaning.
--   * otherwise the name lowercased with every run of non-alphanumerics
--     collapsed to one space.
--
-- The honest limit, stated rather than hidden: two vouchers for the same
-- shop where one carries an NTN and the other does not will NOT match. A
-- payee master (FR-L10's natural home) is what fixes that; a fuzzy match
-- between an NTN and a name would be a guess, and a control that guesses
-- is worse than one with a known edge.
--
-- The group is (tenant, campus, head, voucher_date, payee_key) and counts
-- every sibling that is not rejected — a rejected voucher is money that is
-- not going anywhere.
--
-- WHICH VOUCHERS ESCALATE. The AC only asks for the second. Escalating
-- only the second is not a control: submit two PKR 20,000 vouchers, let the
-- first self-approve and pay it, and PKR 20,000 of a PKR 40,000 spend has
-- left the campus without the Principal ever seeing it. So:
--
--   * the NEW voucher is flagged and escalated (AC3, literally);
--   * every sibling that is still 'pending_approval' or 'approved' — that
--     is, every rupee that has NOT yet left — is flagged and pulled back
--     into the queue, an 'approved' one reverting to 'pending_approval';
--   * a sibling that is already 'paid' is FLAGGED ONLY. Its status and its
--     required_approver_role are left exactly as they were. Un-paying a
--     voucher would be rewriting what happened; the flag is what puts it in
--     front of the Principal reviewing the rest of the group.
--
-- The escalated role is the highest of: the role the voucher's OWN amount
-- needs, the role the GROUP's total needs, and Principal. The group total
-- is what makes the control mean anything (four PKR 60,000 vouchers total
-- PKR 240,000 and reach the Owner, not the Principal), and the Principal
-- floor is AC3's own words for the case where the total is still small.
--
-- The re-opening is itself written to the approval trail, as a row with
-- decision 'escalated' and no approver — the trail has to explain why an
-- approved voucher is back in the queue, and an append-only table cannot
-- explain it any other way.
--
-- ── AC4: the approval table no role can update or delete ───────────────
--
-- FR-T02 (20260731870000) established this codebase's pattern for
-- append-only against a Super Admin who has SQL, and FR-T08
-- (20260731900000) extended it with a TRUNCATE guard. The threat model is
-- unchanged: a role reaching Postgres as `authenticated` (every application
-- role does, super_admin included), a leaked service_role key, and the
-- table owner. Only a database superuser who drops the triggers is out of
-- scope, as it was for both of those.
--
--   1. RLS. expense_approval_update_denied and expense_approval_delete_denied
--      have USING clauses that are verbatim copies of the table's SELECT
--      predicate, and WITH CHECK false on the update. Following FR-T08's
--      reasoning: USING only decides which rows are OFFERED to the
--      statement, and every row it offers is one the caller can already
--      SELECT, so a refusal can never confirm the existence of a row the
--      caller could not already read. What it buys is that the refusal
--      comes from the trigger with a message, instead of arriving as a
--      silent `UPDATE 0` that looks like success.
--
--      FR-T08 deliberately kept DELETE at USING false so that a statement
--      trigger's audit row could survive the aborted transaction. There is
--      no such audit row here — AC4 asks for refusal, not for a record of
--      the attempt — so DELETE is treated exactly like UPDATE and refuses
--      loudly for every caller instead of silently for one of them.
--   2. trg_expense_approval_no_update / _no_delete fire BEFORE ... FOR EACH
--      ROW regardless of caller, so service_role's BYPASSRLS buys nothing.
--      Unlike FR-T08's register, which had three sanctioned transitions,
--      this table has NONE: there is no legal update and no legal delete,
--      so the triggers raise unconditionally and no allow-list, frame check
--      or frozen-column set is needed to express it.
--   3. trg_expense_approval_no_truncate. TRUNCATE fires no row-level
--      trigger and consults no RLS policy at all, so an append-only table
--      that only guards DELETE can still be emptied in one statement by
--      anyone holding it. It must be its own statement-level trigger;
--      there is nowhere else to catch it.
--
-- expense_voucher_approval.voucher_id is ON DELETE CASCADE, so deleting a
-- voucher tries to cascade into the trail and is refused by (2). That is
-- the intended behaviour and the same one FR-T08 chose: a cascade that
-- quietly took the approval history with it would be the hole this table
-- exists to close.
--
-- ── AC4: the request IP, and what it is actually worth ─────────────────
--
-- inet_client_addr() is available inside Postgres and is USELESS here:
-- behind PostgREST and Supabase's pooler it reports the pooler's address,
-- identical for every user in the tenant. Storing it would put a number in
-- the column and no information in the record.
--
-- The client address only exists in the app layer, so it is passed in:
-- decide_expense_voucher(..., p_request_ip text), read by the server action
-- from the request's `x-forwarded-for` (first hop) or `x-real-ip`, parsed
-- by app.fn_parse_request_ip() which returns NULL rather than raising on
-- anything that is not an address.
--
-- Its limits, stated plainly because an audit column that overstates itself
-- is worse than an empty one:
--
--   * `x-forwarded-for` is CLIENT-SUPPLIED unless a proxy overwrites it.
--     Behind a trusted ingress (Vercel, a correctly configured nginx) the
--     first hop is the real peer and this is evidence. On a deployment that
--     puts Next.js directly on the internet, a caller can send whatever
--     they like and this is a claim, not evidence.
--   * A direct-to-origin request carries no such header at all, so the
--     column is NULL. NULL means "not recorded", never 0.0.0.0, and the
--     column is nullable for exactly that reason — a NOT NULL here would
--     only have forced a lie into it.
--   * It records where the request came FROM. Who it came from is
--     approver_id, which comes from the JWT and is not spoofable.
--
-- ── Deliberate departures from the FR's suggested objects ──────────────
--
--   * amount is bigint paisa, not numeric. See above.
--   * payee_key is added beside payee_name/payee_ntn. AC3 is unimplementable
--     as an exact string match.
--   * expense_head is created here at its minimum (code, names, active,
--     requires_approval) because a voucher needs a head to point at.
--     FR-L10 owns this table's chart-of-accounts life — budgets, parent/
--     child heads, per-head period limits — and will extend it. Nothing
--     here presumes a shape for that.
--   * fn_required_approver_role keeps the FR's three-argument signature.
--     head_id is not decoration: expense_head.requires_approval lets a head
--     like a cash advance demand a Principal at any amount, which is the
--     only reason a routing function would need to know the head at all.
--
-- Every function below has its full signature fixed. Adding a defaulted
-- argument with CREATE OR REPLACE creates a DISTINCT overload and makes
-- existing calls ambiguous (FR-G05 hit exactly this) — drop and recreate,
-- and re-issue the grants.

-- ═══════════════════════════════════════════════════════════════════════
-- Enums
-- ═══════════════════════════════════════════════════════════════════════

create type public.expense_voucher_status as enum (
  'pending_approval', 'approved', 'rejected', 'paid'
);

create type public.expense_approval_decision as enum (
  'approved', 'rejected', 'escalated'
);

-- ═══════════════════════════════════════════════════════════════════════
-- expense_head — the minimum a voucher needs to point at. FR-L10 extends.
-- ═══════════════════════════════════════════════════════════════════════

create table public.expense_head (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  code              text not null,
  name_en           text not null,
  name_ur           text not null,
  -- A head that always needs a Principal regardless of amount. This is the
  -- whole reason fn_required_approver_role takes a head_id.
  requires_approval boolean not null default false,
  is_active         boolean not null default true,
  created_by        uuid references public.app_user(user_id),
  created_at        timestamptz not null default now()
);

-- Case-insensitive, same as fee_head: a tenant with both CASH_ADVANCE and
-- cash_advance has two heads that reconcile to one line in any report.
create unique index expense_head_tenant_code_uq on public.expense_head (tenant_id, lower(code));
create index idx_expense_head_tenant_active on public.expense_head (tenant_id, is_active);

create trigger expense_head_audit after insert or update or delete on public.expense_head
  for each row execute function app.tg_audit_row();

alter table public.expense_head enable row level security;

create policy expense_head_tenant_read on public.expense_head
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create or replace function public.seed_default_expense_heads(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.expense_head (tenant_id, code, name_en, name_ur, requires_approval) values
    (p_tenant_id, 'UTILITIES',   'Utilities',              'یوٹیلٹی بل',    false),
    (p_tenant_id, 'REPAIRS',     'Repairs & Maintenance',  'مرمت',          false),
    (p_tenant_id, 'STATIONERY',  'Stationery & Printing',  'اسٹیشنری',      false),
    (p_tenant_id, 'TRANSPORT',   'Transport & Fuel',       'ٹرانسپورٹ',     false),
    (p_tenant_id, 'FURNITURE',   'Furniture & Equipment',  'فرنیچر',        false),
    (p_tenant_id, 'EVENTS',      'Events & Functions',     'تقریبات',       false),
    -- Money handed over before anything is bought is the classic hole in an
    -- expense control, so this head needs a sign-off at any amount.
    (p_tenant_id, 'CASH_ADVANCE', 'Cash Advance',          'پیشگی رقم',     true)
  on conflict do nothing;
end;
$$;

-- No tenant check inside, because it runs from provision_tenant before any
-- user exists to check against — so it is not reachable from the
-- application at all. A tenant that wants more heads calls
-- create_expense_head(), which is scoped to the caller's own tenant.
revoke execute on function public.seed_default_expense_heads(uuid) from public, anon, authenticated;

create or replace function public.create_expense_head(
  p_code text,
  p_name_en text,
  p_name_ur text,
  p_requires_approval boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if coalesce(btrim(p_code), '') = '' then
    raise exception 'EXPENSE_HEAD_CODE_REQUIRED' using errcode = '23514';
  end if;

  insert into public.expense_head (tenant_id, code, name_en, name_ur, requires_approval, created_by)
  values (app.auth_tenant_id(), btrim(p_code), p_name_en, p_name_ur, p_requires_approval, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_expense_head(text, text, text, boolean) from public, anon;
grant execute on function public.create_expense_head(text, text, text, boolean) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- approval_threshold — AC1's bands, in paisa, per campus
-- ═══════════════════════════════════════════════════════════════════════

create table public.approval_threshold (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  min_amount_paisa  bigint not null check (min_amount_paisa >= 0),
  -- NULL means unbounded above: the top band has no ceiling.
  max_amount_paisa  bigint check (max_amount_paisa is null or max_amount_paisa >= min_amount_paisa),
  -- NULL means self-approval: nobody above the submitter is needed.
  required_role     public.app_role,
  created_at        timestamptz not null default now(),
  constraint chk_approval_threshold_role
    check (required_role is null or required_role in ('vice_principal', 'principal', 'owner', 'super_admin')),
  -- Two bands claiming the same rupee is a routing decision made by
  -- whichever row the planner happened to read first. int8range is discrete
  -- so an inclusive ceiling is written as an exclusive max+1.
  constraint approval_threshold_no_overlap exclude using gist (
    campus_id with =,
    int8range(
      min_amount_paisa,
      case when max_amount_paisa is null then null else max_amount_paisa + 1 end,
      '[)'
    ) with &&
  )
);

create index idx_approval_threshold_campus on public.approval_threshold (campus_id, min_amount_paisa);

create trigger approval_threshold_audit after insert or update or delete on public.approval_threshold
  for each row execute function app.tg_audit_row();

alter table public.approval_threshold enable row level security;

create policy approval_threshold_tenant_read on public.approval_threshold
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- AC1's three bands, in paisa. A campus is created from provision_tenant
-- and from create_campus, so this hangs off the table rather than off
-- either function — every path that ever creates a campus, including ones
-- written later, gets a routed campus and not a silent one.
create or replace function app.tg_campus_seed_approval_thresholds()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.approval_threshold (tenant_id, campus_id, min_amount_paisa, max_amount_paisa, required_role) values
    (new.tenant_id, new.id,           0,  2500000, null),
    (new.tenant_id, new.id,     2500001, 20000000, 'principal'),
    (new.tenant_id, new.id,    20000001,     null, 'owner');
  return new;
end;
$$;

create trigger trg_campus_seed_approval_thresholds
  after insert on public.campus
  for each row execute function app.tg_campus_seed_approval_thresholds();

-- Any campus that already exists. A `db reset` has none at this point (every
-- campus is created by a later provision_tenant call), but a database this
-- migration lands on top of does.
insert into public.approval_threshold (tenant_id, campus_id, min_amount_paisa, max_amount_paisa, required_role)
select c.tenant_id, c.id, b.lo, b.hi, b.role
  from public.campus c
 cross join (values (0::bigint, 2500000::bigint, null::public.app_role),
                    (2500001, 20000000, 'principal'),
                    (20000001, null, 'owner')) as b(lo, hi, role)
 where not exists (select 1 from public.approval_threshold t where t.campus_id = c.id);

-- The one writer of a band from the application. Bands are money policy, so
-- only an Owner or Super Admin moves one — a Principal raising their own
-- ceiling is the control approving of its own removal.
create or replace function public.set_approval_threshold(
  p_campus_id uuid,
  p_min_amount_paisa bigint,
  p_max_amount_paisa bigint,
  p_required_role public.app_role
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- SECURITY DEFINER runs as the table owner and is not subject to RLS, so
  -- the tenant predicate is written out (b16ba25's convention, restated by
  -- FR-K24's hardening pass).
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_min_amount_paisa is null or p_min_amount_paisa < 0 then
    raise exception 'THRESHOLD_RANGE_INVALID' using errcode = '23514', detail = 'min_amount_paisa';
  end if;
  if p_max_amount_paisa is not null and p_max_amount_paisa < p_min_amount_paisa then
    raise exception 'THRESHOLD_RANGE_INVALID' using errcode = '23514', detail = 'max below min';
  end if;

  insert into public.approval_threshold (tenant_id, campus_id, min_amount_paisa, max_amount_paisa, required_role)
  values (v_tenant_id, p_campus_id, p_min_amount_paisa, p_max_amount_paisa, p_required_role)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_approval_threshold(uuid, bigint, bigint, public.app_role) from public, anon;
grant execute on function public.set_approval_threshold(uuid, bigint, bigint, public.app_role) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Routing helpers
-- ═══════════════════════════════════════════════════════════════════════

-- The approval ladder, as one number so "is this approver senior enough"
-- and "which of these two roles is stricter" are the same comparison.
-- 0 is the submitter themselves, which is exactly enough for a
-- self-approval band and never enough for anything above it.
create or replace function app.fn_expense_role_rank(p_role public.app_role)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_role
           when 'vice_principal' then 1
           when 'principal'      then 2
           when 'owner'          then 3
           when 'super_admin'    then 4
           else 0
         end;
$$;

-- AC1's routing. Returns NULL for the self-approval band.
--
-- Fails CLOSED: a campus whose bands have a hole in them (someone deleted
-- the middle one) routes to 'owner' rather than falling through to
-- self-approval. Under-approving is the failure that costs money.
create or replace function public.fn_required_approver_role(
  p_campus_id uuid,
  p_amount_paisa bigint,
  p_head_id uuid
)
returns public.app_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_band_role public.app_role;
  v_found     boolean;
  v_head_role public.app_role;
begin
  select t.required_role, true
    into v_band_role, v_found
    from public.approval_threshold t
   where t.campus_id = p_campus_id
     and p_amount_paisa >= t.min_amount_paisa
     and (t.max_amount_paisa is null or p_amount_paisa <= t.max_amount_paisa)
   order by t.min_amount_paisa desc
   limit 1;

  if not coalesce(v_found, false) then
    return 'owner';
  end if;

  -- A head that demands a sign-off at any amount (a cash advance) can only
  -- ever raise the bar, never lower it.
  select case when h.requires_approval then 'principal'::public.app_role else null end
    into v_head_role
    from public.expense_head h
   where h.id = p_head_id;

  if app.fn_expense_role_rank(v_head_role) > app.fn_expense_role_rank(v_band_role) then
    return v_head_role;
  end if;
  return v_band_role;
end;
$$;

revoke execute on function public.fn_required_approver_role(uuid, bigint, uuid) from public, anon;
grant execute on function public.fn_required_approver_role(uuid, bigint, uuid) to authenticated, service_role;

-- AC3's identity for a payee. See the header for the NTN-vs-name limit.
create or replace function app.fn_expense_payee_key(p_payee_name text, p_payee_ntn text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    nullif('ntn:' || regexp_replace(coalesce(p_payee_ntn, ''), '[^0-9]', '', 'g'), 'ntn:'),
    'name:' || btrim(regexp_replace(lower(coalesce(p_payee_name, '')), '[^a-z0-9]+', ' ', 'g'))
  );
$$;

-- AC4's IP. Returns NULL for anything that is not an address, because a
-- column that says "not recorded" is worth more than one that says 0.0.0.0.
create or replace function app.fn_parse_request_ip(p_value text)
returns inet
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  return btrim(p_value)::inet;
exception
  when others then
    return null;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- expense_voucher
-- ═══════════════════════════════════════════════════════════════════════

create table public.expense_voucher (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  campus_id               uuid not null references public.campus(id) on delete cascade,
  head_id                 uuid not null references public.expense_head(id),
  payee_name              text not null check (btrim(payee_name) <> ''),
  payee_ntn               text,
  -- Written by trg_expense_voucher_route, never by a caller. A STORED
  -- generated column would be computed AFTER the BEFORE INSERT trigger and
  -- so would not be visible to the split detection that needs it.
  payee_key               text not null,
  amount_paisa            bigint not null check (amount_paisa > 0),
  voucher_date            date not null,
  narrative               text,
  status                  public.expense_voucher_status not null default 'pending_approval',
  -- NULL = the self-approval band. Frozen once the voucher is paid.
  required_approver_role  public.app_role,
  possible_threshold_split boolean not null default false,
  attachment_path         text,
  paid_at                 timestamptz,
  paid_by                 uuid references public.app_user(user_id),
  paid_reference          text,
  created_by              uuid references public.app_user(user_id),
  created_at              timestamptz not null default now(),
  constraint chk_expense_voucher_paid_fields
    check ((status = 'paid') = (paid_at is not null))
);

-- The split lookup (AC3) and the pending queue read (AC1).
create index idx_expense_voucher_split
  on public.expense_voucher (tenant_id, campus_id, head_id, voucher_date, payee_key);
create index idx_expense_voucher_queue
  on public.expense_voucher (tenant_id, status, campus_id, voucher_date desc);
create index idx_expense_voucher_created_by on public.expense_voucher (created_by, created_at desc);

create trigger expense_voucher_audit after insert or update or delete on public.expense_voucher
  for each row execute function app.tg_audit_row();

-- ═══════════════════════════════════════════════════════════════════════
-- expense_voucher_approval — AC4's append-only trail
-- ═══════════════════════════════════════════════════════════════════════

create table public.expense_voucher_approval (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  voucher_id    uuid not null references public.expense_voucher(id) on delete cascade,
  -- NULL only for a system escalation, which has no human approver.
  approver_id   uuid references public.app_user(user_id),
  approver_role public.app_role,
  decision      public.expense_approval_decision not null,
  reason        text,
  -- See the header: NULL means the request carried no forwarded address,
  -- never that the approver had no address.
  request_ip    inet,
  decided_at    timestamptz not null default clock_timestamp(),
  constraint chk_expense_approval_actor
    check ((decision = 'escalated') or (approver_id is not null and approver_role is not null)),
  -- AC2, at the level nothing can route around.
  constraint chk_expense_approval_reason
    check (decision <> 'rejected' or length(btrim(coalesce(reason, ''))) >= 10)
);

create index idx_expense_approval_voucher on public.expense_voucher_approval (voucher_id, decided_at);

-- No audit trigger. The table IS the audit record, it can never change, and
-- a second copy of every row in audit_log would be a competing history that
-- could only ever disagree with this one.

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 + AC3: routing at INSERT
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.tg_expense_voucher_route()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sibling_total bigint;
  v_sibling_count int;
  v_own_role      public.app_role;
  v_group_role    public.app_role;
begin
  new.payee_key := app.fn_expense_payee_key(new.payee_name, new.payee_ntn);
  new.status    := 'pending_approval';
  new.paid_at   := null;
  new.paid_by   := null;

  v_own_role := public.fn_required_approver_role(new.campus_id, new.amount_paisa, new.head_id);

  -- AC3. A rejected sibling is money that is not going anywhere, so it is
  -- not part of the group.
  select coalesce(sum(v.amount_paisa), 0), count(*)
    into v_sibling_total, v_sibling_count
    from public.expense_voucher v
   where v.tenant_id    = new.tenant_id
     and v.campus_id    = new.campus_id
     and v.head_id      = new.head_id
     and v.voucher_date = new.voucher_date
     and v.payee_key    = new.payee_key
     and v.status <> 'rejected';

  if v_sibling_count > 0 then
    new.possible_threshold_split := true;
    v_group_role := public.fn_required_approver_role(
      new.campus_id, new.amount_paisa + v_sibling_total, new.head_id);

    -- The strictest of: what this voucher needs alone, what the group needs
    -- together, and AC3's Principal floor.
    new.required_approver_role := v_own_role;
    if app.fn_expense_role_rank(v_group_role) > app.fn_expense_role_rank(new.required_approver_role) then
      new.required_approver_role := v_group_role;
    end if;
    if app.fn_expense_role_rank('principal') > app.fn_expense_role_rank(new.required_approver_role) then
      new.required_approver_role := 'principal';
    end if;
  else
    new.possible_threshold_split := false;
    new.required_approver_role   := v_own_role;
  end if;

  -- The self-approval band lands 'approved' at INSERT rather than through a
  -- follow-up UPDATE from submit_expense_voucher(): the status guard's
  -- allow-list would otherwise need a fourth transition that exists purely
  -- to undo what this trigger just decided. submit_expense_voucher() writes
  -- the matching approval row immediately afterwards, and a row inserted by
  -- any other route reaches 'approved' with an empty trail — which
  -- mark_expense_voucher_paid()'s guard refuses to pay.
  if new.required_approver_role is null then
    new.status := 'approved';
  end if;

  return new;
end;
$$;

create trigger trg_expense_voucher_route
  before insert on public.expense_voucher
  for each row execute function app.tg_expense_voucher_route();

-- AC3's other half: the siblings. Runs AFTER INSERT because it updates rows
-- other than this one, and its frame is what the status guard's allow-list
-- recognises for the approved -> pending_approval reversal.
create or replace function app.tg_flag_threshold_split()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_total bigint;
  v_sibling     record;
  v_role        public.app_role;
begin
  if not new.possible_threshold_split then
    return null;
  end if;

  select coalesce(sum(v.amount_paisa), 0)
    into v_group_total
    from public.expense_voucher v
   where v.tenant_id    = new.tenant_id
     and v.campus_id    = new.campus_id
     and v.head_id      = new.head_id
     and v.voucher_date = new.voucher_date
     and v.payee_key    = new.payee_key
     and v.status <> 'rejected';

  for v_sibling in
    select v.id, v.amount_paisa, v.status, v.required_approver_role, v.possible_threshold_split
      from public.expense_voucher v
     where v.tenant_id    = new.tenant_id
       and v.campus_id    = new.campus_id
       and v.head_id      = new.head_id
       and v.voucher_date = new.voucher_date
       and v.payee_key    = new.payee_key
       and v.id <> new.id
       and v.status <> 'rejected'
     for update
  loop
    -- A voucher that is already paid keeps its status and the role that was
    -- required of it at the time. The money has left; only the flag is
    -- still true and still worth recording.
    if v_sibling.status = 'paid' then
      if not v_sibling.possible_threshold_split then
        update public.expense_voucher set possible_threshold_split = true where id = v_sibling.id;
      end if;
      continue;
    end if;

    v_role := public.fn_required_approver_role(new.campus_id, v_group_total, new.head_id);
    if app.fn_expense_role_rank('principal') > app.fn_expense_role_rank(v_role) then
      v_role := 'principal';
    end if;
    if app.fn_expense_role_rank(v_sibling.required_approver_role) > app.fn_expense_role_rank(v_role) then
      v_role := v_sibling.required_approver_role;
    end if;

    update public.expense_voucher
       set possible_threshold_split = true,
           required_approver_role   = v_role,
           status                   = 'pending_approval'
     where id = v_sibling.id;

    -- An append-only trail has to explain why an approved voucher is back
    -- in the queue, and this row is the only place it can say so.
    if v_sibling.status = 'approved' then
      insert into public.expense_voucher_approval (tenant_id, voucher_id, decision, reason)
      values (
        new.tenant_id, v_sibling.id, 'escalated',
        format('Re-opened for approval: possible threshold split with voucher %s (same payee, head and date; group total %s paisa).',
               new.id, v_group_total)
      );
    end if;
  end loop;

  return null;
end;
$$;

create trigger trg_flag_threshold_split
  after insert on public.expense_voucher
  for each row execute function app.tg_flag_threshold_split();

-- ═══════════════════════════════════════════════════════════════════════
-- AC1 + AC2: the status guard
-- ═══════════════════════════════════════════════════════════════════════

-- SECURITY INVOKER on purpose, exactly as FR-T02's counter trigger and
-- FR-T08's register trigger: current_user must still report the executing
-- context, so "the caller is the table owner" means "we are inside a
-- SECURITY DEFINER function running as the owner" and not "a logged-in
-- role".
create or replace function app.tg_expense_voucher_status_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack  text;
  v_owner  text;
  v_frozen boolean;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  -- What the voucher SAYS. Frozen for every status, not only 'rejected':
  -- an approved voucher whose amount could still be edited would make the
  -- approval worthless. Checked once, so a column added later is frozen by
  -- default and has to be argued out of this list rather than into it.
  v_frozen :=
        new.id           is not distinct from old.id
    and new.tenant_id    is not distinct from old.tenant_id
    and new.campus_id    is not distinct from old.campus_id
    and new.head_id      is not distinct from old.head_id
    and new.payee_name   is not distinct from old.payee_name
    and new.payee_ntn    is not distinct from old.payee_ntn
    and new.payee_key    is not distinct from old.payee_key
    and new.amount_paisa is not distinct from old.amount_paisa
    and new.voucher_date is not distinct from old.voucher_date
    and new.narrative    is not distinct from old.narrative
    and new.attachment_path is not distinct from old.attachment_path
    and new.created_by   is not distinct from old.created_by
    and new.created_at   is not distinct from old.created_at;

  if current_user = v_owner and v_frozen and old.status <> 'rejected' then
    -- A. The decision. Both directions out of the queue.
    if v_stack ~ 'function public\.decide_expense_voucher\('
       and old.status = 'pending_approval'
       and new.status in ('approved', 'rejected')
       and new.possible_threshold_split is not distinct from old.possible_threshold_split
       and new.required_approver_role   is not distinct from old.required_approver_role
       and new.paid_at is null
    then
      return new;
    end if;

    -- B. Payment. AC1's "CANNOT be marked paid": the test is against the
    -- append-only trail, not against the voucher's own status column, so
    -- there is no sequence of updates that reaches 'paid' without a real
    -- approval of sufficient rank behind it.
    if v_stack ~ 'function public\.mark_expense_voucher_paid\('
       and old.status = 'approved'
       and new.status = 'paid'
       and new.possible_threshold_split is not distinct from old.possible_threshold_split
       and new.required_approver_role   is not distinct from old.required_approver_role
       and new.paid_at is not null
       and exists (
         select 1 from public.expense_voucher_approval a
          where a.voucher_id = old.id
            and a.decision = 'approved'
            and a.decided_at > coalesce(
              (select e.decided_at from public.expense_voucher_approval e
                where e.voucher_id = old.id and e.decision = 'escalated'
                order by e.decided_at desc limit 1),
              '-infinity'::timestamptz)
            and app.fn_expense_role_rank(a.approver_role)
                >= app.fn_expense_role_rank(old.required_approver_role)
       )
    then
      return new;
    end if;

    -- C. AC3's escalation: the flag, the raised role, and an approved
    -- voucher going back into the queue. Never out of 'paid' into anything
    -- else — a paid sibling may only gain the flag.
    if v_stack ~ 'function app\.tg_flag_threshold_split\('
       and new.possible_threshold_split
       and new.paid_at is not distinct from old.paid_at
       and new.paid_by is not distinct from old.paid_by
       and (
         (old.status in ('pending_approval', 'approved') and new.status = 'pending_approval'
          and app.fn_expense_role_rank(new.required_approver_role)
              >= app.fn_expense_role_rank(old.required_approver_role))
         or (old.status = 'paid' and new.status = 'paid'
             and new.required_approver_role is not distinct from old.required_approver_role)
       )
    then
      return new;
    end if;
  end if;

  raise exception 'expense voucher transition refused'
    using errcode = '42501',
          detail = format('update of expense_voucher id=%s status=%s->%s amount_paisa=%s by %s',
                          old.id, old.status, new.status, old.amount_paisa, current_user),
          hint = 'A voucher''s payee, head, amount, date and attachment are fixed once submitted. '
              || 'It reaches ''paid'' only through mark_expense_voucher_paid() after an approval of the required rank, '
              || 'and a rejected voucher is final — correct it by submitting a new one.';
end;
$$;

create trigger trg_expense_voucher_status_guard
  before update on public.expense_voucher
  for each row execute function app.tg_expense_voucher_status_guard();

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the trail no role can update or delete
-- ═══════════════════════════════════════════════════════════════════════

-- No sanctioned transition exists, so unlike FR-T08's register there is no
-- allow-list to consult: every UPDATE is refused, from every caller.
create or replace function app.tg_expense_approval_no_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'expense approval trail is append-only'
    using errcode = '42501',
          detail = format('update of expense_voucher_approval id=%s voucher_id=%s decision=%s by %s',
                          old.id, old.voucher_id, old.decision, current_user),
          hint = 'An approval is a signature. It is recorded once and never revised; record a new decision instead.';
end;
$$;

create trigger trg_expense_approval_no_update
  before update on public.expense_voucher_approval
  for each row execute function app.tg_expense_approval_no_update();

create or replace function app.tg_expense_approval_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'expense approval trail is append-only'
    using errcode = '42501',
          detail = format('delete of expense_voucher_approval id=%s voucher_id=%s decision=%s by %s',
                          old.id, old.voucher_id, old.decision, current_user),
          hint = 'The trail keeps every decision it ever held, including the ones that were superseded.';
end;
$$;

create trigger trg_expense_approval_no_delete
  before delete on public.expense_voucher_approval
  for each row execute function app.tg_expense_approval_no_delete();

-- TRUNCATE fires no row-level trigger and is filtered by no RLS policy, so
-- without this the whole trail is one statement away from empty for anyone
-- holding the table. There is nowhere else to catch it.
create or replace function app.tg_expense_approval_no_truncate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'expense approval trail is append-only'
    using errcode = '42501',
          detail = format('truncate of expense_voucher_approval by %s', current_user),
          hint = 'The trail keeps every decision it ever held.';
end;
$$;

create trigger trg_expense_approval_no_truncate
  before truncate on public.expense_voucher_approval
  for each statement execute function app.tg_expense_approval_no_truncate();

-- ═══════════════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════════════

alter table public.expense_voucher enable row level security;

-- Who can see a voucher: the money roles at their own campuses, an Owner or
-- Super Admin anywhere in the tenant, and always the person who submitted
-- it — a clerk has to be able to watch their own voucher move.
create policy expense_voucher_campus_scope on public.expense_voucher
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or (app.auth_role() in ('principal', 'vice_principal', 'accountant')
          and campus_id = any(app.auth_campus_ids()))
      or created_by = (select auth.uid())
    )
  );

-- There is no INSERT policy: submit_expense_voucher() is the only writer,
-- and a direct INSERT is refused by RLS with a message rather than silently.
--
-- UPDATE and DELETE are denied with the read predicate as USING rather than
-- `false`, following FR-T08: the rows offered are exactly the rows the
-- caller can already read, so nothing is disclosed, and the refusal arrives
-- from the status guard with its reason instead of as a silent `UPDATE 0`.
create policy expense_voucher_update_denied on public.expense_voucher
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or (app.auth_role() in ('principal', 'vice_principal', 'accountant')
          and campus_id = any(app.auth_campus_ids()))
      or created_by = (select auth.uid())
    )
  )
  with check (false);

alter table public.expense_voucher_approval enable row level security;

-- The trail is readable by whoever can read the voucher it belongs to, so
-- the two can never disagree about who is allowed to see a decision.
create policy expense_approval_role_scope on public.expense_voucher_approval
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exists (
      select 1 from public.expense_voucher v
       where v.id = expense_voucher_approval.voucher_id
         and v.tenant_id = app.auth_tenant_id()
         and (
           app.auth_role() in ('super_admin', 'owner')
           or (app.auth_role() in ('principal', 'vice_principal', 'accountant')
               and v.campus_id = any(app.auth_campus_ids()))
           or v.created_by = (select auth.uid())
         )
    )
  );

create policy expense_approval_update_denied on public.expense_voucher_approval
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exists (
      select 1 from public.expense_voucher v
       where v.id = expense_voucher_approval.voucher_id
         and v.tenant_id = app.auth_tenant_id()
         and (
           app.auth_role() in ('super_admin', 'owner')
           or (app.auth_role() in ('principal', 'vice_principal', 'accountant')
               and v.campus_id = any(app.auth_campus_ids()))
           or v.created_by = (select auth.uid())
         )
    )
  )
  with check (false);

create policy expense_approval_delete_denied on public.expense_voucher_approval
  for delete to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and exists (
      select 1 from public.expense_voucher v
       where v.id = expense_voucher_approval.voucher_id
         and v.tenant_id = app.auth_tenant_id()
         and (
           app.auth_role() in ('super_admin', 'owner')
           or (app.auth_role() in ('principal', 'vice_principal', 'accountant')
               and v.campus_id = any(app.auth_campus_ids()))
           or v.created_by = (select auth.uid())
         )
    )
  );

-- ═══════════════════════════════════════════════════════════════════════
-- Attachments
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('expense-attachments', 'expense-attachments', false, 5242880,
        array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

-- Returns a path, not a row: the bill is uploaded before the voucher row
-- exists, so a failed submit leaves an object nobody can read (the bucket's
-- SELECT policy needs a voucher pointing at it) rather than a voucher with a
-- broken attachment. Same posture as FR-T15's consent evidence.
create or replace function public.reserve_expense_attachment_path(
  p_campus_id uuid,
  p_file_ext  text,
  p_file_size int,
  p_mime_type text
)
returns text
-- Deliberately VOLATILE: every call must mint a new uuid.
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_file_size is null or p_file_size <= 0 or p_file_size > 5242880 then
    raise exception 'FILE_TOO_LARGE' using errcode = '23514', detail = 'Maximum file size 5 MB';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png', 'application/pdf') then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '23514';
  end if;
  if p_file_ext is null or p_file_ext !~ '^[a-z0-9]{1,5}$' then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '23514', detail = 'file extension';
  end if;

  return v_tenant_id::text || '/' || p_campus_id::text || '/' || gen_random_uuid()::text || '.' || p_file_ext;
end;
$$;

revoke execute on function public.reserve_expense_attachment_path(uuid, text, int, text) from public, anon;
grant execute on function public.reserve_expense_attachment_path(uuid, text, int, text) to authenticated;

create policy expense_attachment_insert_staff on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'expense-attachments'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant')
    and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text
    and exists (
      -- objects.name, qualified: public.campus has its own `name` column, and
      -- an unqualified `name` inside this subquery binds to THAT, silently
      -- comparing a campus id to a campus name and refusing every upload.
      select 1 from public.campus c
       where c.id::text = (storage.foldername(objects.name))[2]
         and c.tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or c.id = any(app.auth_campus_ids()))
    )
  );

-- Readable only once a voucher claims it, and then to exactly whoever can
-- read that voucher.
create policy expense_attachment_read_scope on storage.objects
  for select to authenticated
  using (
    bucket_id = 'expense-attachments'
    and exists (
      select 1 from public.expense_voucher v
       where v.attachment_path = objects.name
         and v.tenant_id = app.auth_tenant_id()
         and (
           app.auth_role() in ('super_admin', 'owner')
           or (app.auth_role() in ('principal', 'vice_principal', 'accountant')
               and v.campus_id = any(app.auth_campus_ids()))
           or v.created_by = (select auth.uid())
         )
    )
  );

-- ═══════════════════════════════════════════════════════════════════════
-- The write paths
-- ═══════════════════════════════════════════════════════════════════════

-- AC1's submission. Returns what the submitter needs to be told: who this
-- has gone to, and whether it tripped AC3's split check.
--
-- A self-approval band still writes an approval row. "Self-approved" is a
-- decision somebody made and AC4 asks for every approval to carry an
-- approver, a role, a time and an address — a band with no one above the
-- submitter changes who signs, not whether anyone does.
create or replace function public.submit_expense_voucher(
  p_campus_id       uuid,
  p_head_id         uuid,
  p_payee_name      text,
  p_amount_paisa    bigint,
  p_voucher_date    date,
  p_payee_ntn       text default null,
  p_narrative       text default null,
  p_attachment_path text default null,
  p_request_ip      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_uid       uuid := (select auth.uid());
  v_voucher   public.expense_voucher%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'vice_principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_tenant_id is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- SECURITY DEFINER bypasses RLS, so tenant and campus scope are checked
  -- explicitly rather than left to a policy that will not run.
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.expense_head where id = p_head_id and tenant_id = v_tenant_id and is_active) then
    raise exception 'EXPENSE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_amount_paisa is null or p_amount_paisa <= 0 then
    raise exception 'VOUCHER_AMOUNT_INVALID' using errcode = '23514';
  end if;
  if coalesce(btrim(p_payee_name), '') = '' then
    raise exception 'VOUCHER_PAYEE_REQUIRED' using errcode = '23514';
  end if;
  if p_voucher_date is null or p_voucher_date > current_date then
    raise exception 'VOUCHER_DATE_INVALID'
      using errcode = '23514', hint = 'A voucher cannot be dated in the future.';
  end if;
  if p_attachment_path is not null
     and p_attachment_path not like v_tenant_id::text || '/' || p_campus_id::text || '/%' then
    raise exception 'ATTACHMENT_PATH_MISMATCH' using errcode = '23514';
  end if;

  -- Serialise submissions for one payee/head/date so two clerks splitting a
  -- payment at the same instant cannot both read "no siblings" and both
  -- self-approve. AC3's whole point is the second submission seeing the
  -- first.
  perform pg_advisory_xact_lock(hashtextextended(
    'expense-split:' || p_campus_id::text || ':' || p_head_id::text || ':' || p_voucher_date::text
    || ':' || app.fn_expense_payee_key(p_payee_name, p_payee_ntn), 0));

  insert into public.expense_voucher (
    tenant_id, campus_id, head_id, payee_name, payee_ntn, payee_key,
    amount_paisa, voucher_date, narrative, attachment_path, created_by
  ) values (
    v_tenant_id, p_campus_id, p_head_id, btrim(p_payee_name), nullif(btrim(coalesce(p_payee_ntn, '')), ''), '',
    p_amount_paisa, p_voucher_date, nullif(btrim(coalesce(p_narrative, '')), ''), p_attachment_path, v_uid
  )
  returning * into v_voucher;

  -- The self-approval band: nobody above the submitter is required, so the
  -- submitter's own sign-off IS the approval and is recorded as one, with
  -- the same four things AC4 asks of every other approval. The route
  -- trigger has already set the status; this writes the signature under it.
  if v_voucher.required_approver_role is null then
    insert into public.expense_voucher_approval (
      tenant_id, voucher_id, approver_id, approver_role, decision, reason, request_ip
    ) values (
      v_tenant_id, v_voucher.id, v_uid, v_role::public.app_role, 'approved',
      'Self-approved: within the campus self-approval limit.', app.fn_parse_request_ip(p_request_ip)
    );
  end if;

  return jsonb_build_object(
    'voucher_id',               v_voucher.id,
    'status',                   v_voucher.status,
    'amount_paisa',             v_voucher.amount_paisa,
    'required_approver_role',   v_voucher.required_approver_role,
    'possible_threshold_split', v_voucher.possible_threshold_split
  );
end;
$$;

revoke execute on function public.submit_expense_voucher(uuid, uuid, text, bigint, date, text, text, text, text) from public, anon;
grant execute on function public.submit_expense_voucher(uuid, uuid, text, bigint, date, text, text, text, text) to authenticated;

-- AC2 + AC4. The only writer of an approval decision.
create or replace function public.decide_expense_voucher(
  p_voucher_id uuid,
  p_decision   text,
  p_reason     text default null,
  p_request_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_uid       uuid := (select auth.uid());
  v_voucher   public.expense_voucher%rowtype;
  v_reason    text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'DECISION_INVALID' using errcode = '22023';
  end if;
  if v_role not in ('super_admin', 'owner', 'principal', 'vice_principal') then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'Only a Vice Principal, Principal, Owner or Super Admin decides a voucher.';
  end if;

  select * into v_voucher from public.expense_voucher
   where id = p_voucher_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'VOUCHER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_voucher.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_voucher.status <> 'pending_approval' then
    raise exception 'VOUCHER_NOT_PENDING'
      using errcode = '55000',
            detail = format('status=%s', v_voucher.status),
            hint = 'Only a voucher waiting in the queue can be decided.';
  end if;

  -- AC1's routing, enforced on the way in as well as on the way out: a
  -- Vice Principal cannot sign off a voucher the bands routed to the Owner.
  if app.fn_expense_role_rank(v_role::public.app_role)
     < app.fn_expense_role_rank(v_voucher.required_approver_role) then
    raise exception 'APPROVER_RANK_INSUFFICIENT'
      using errcode = '42501',
            detail = format('required=%s actual=%s', v_voucher.required_approver_role, v_role),
            hint = 'This voucher is above your approval limit.';
  end if;

  -- AC2. Also a CHECK constraint on the row, so no path can write a short
  -- one; this is the message a person reads.
  if p_decision = 'rejected' and length(coalesce(v_reason, '')) < 10 then
    raise exception 'REJECTION_REASON_TOO_SHORT'
      using errcode = '23514',
            hint = 'A rejection has to say why, in at least 10 characters.';
  end if;

  insert into public.expense_voucher_approval (
    tenant_id, voucher_id, approver_id, approver_role, decision, reason, request_ip
  ) values (
    v_tenant_id, p_voucher_id, v_uid, v_role::public.app_role,
    p_decision::public.expense_approval_decision, v_reason, app.fn_parse_request_ip(p_request_ip)
  );

  update public.expense_voucher
     set status = p_decision::public.expense_voucher_status
   where id = p_voucher_id;

  return jsonb_build_object(
    'voucher_id', p_voucher_id,
    'status',     p_decision,
    'approver_role', v_role,
    'reason',     v_reason
  );
end;
$$;

revoke execute on function public.decide_expense_voucher(uuid, text, text, text) from public, anon;
grant execute on function public.decide_expense_voucher(uuid, text, text, text) to authenticated;

-- AC1's other half. The status guard re-checks the trail independently, so
-- this function's checks are the messages a person reads and not the
-- control itself.
create or replace function public.mark_expense_voucher_paid(
  p_voucher_id uuid,
  p_paid_reference text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_voucher   public.expense_voucher%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_voucher from public.expense_voucher
   where id = p_voucher_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'VOUCHER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_voucher.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_voucher.status <> 'approved' then
    raise exception 'VOUCHER_NOT_APPROVED'
      using errcode = '55000',
            detail = format('status=%s', v_voucher.status),
            hint = 'A voucher is paid only after it has been approved by the role its amount requires.';
  end if;

  update public.expense_voucher
     set status = 'paid',
         paid_at = clock_timestamp(),
         paid_by = (select auth.uid()),
         paid_reference = nullif(btrim(coalesce(p_paid_reference, '')), '')
   where id = p_voucher_id;

  return jsonb_build_object('voucher_id', p_voucher_id, 'status', 'paid');
end;
$$;

revoke execute on function public.mark_expense_voucher_paid(uuid, text) from public, anon;
grant execute on function public.mark_expense_voucher_paid(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Reads
-- ═══════════════════════════════════════════════════════════════════════

-- security_invoker keeps expense_voucher_campus_scope in force, so a
-- Principal sees their own campuses and a clerk sees their own vouchers,
-- with no second place for that decision to be made differently.
create or replace view public.v_expense_voucher
with (security_invoker = true) as
select
  v.id,
  v.tenant_id,
  v.campus_id,
  c.code as campus_code,
  c.name as campus_name,
  v.head_id,
  h.code as head_code,
  h.name_en as head_name,
  v.payee_name,
  v.payee_ntn,
  v.payee_key,
  v.amount_paisa,
  v.voucher_date,
  v.narrative,
  v.status,
  v.required_approver_role,
  v.possible_threshold_split,
  v.attachment_path,
  v.paid_at,
  v.paid_reference,
  payer.full_name as paid_by_name,
  v.created_by,
  submitter.full_name as submitted_by_name,
  v.created_at,
  -- The rest of the group AC3 flagged this voucher against, so the screen
  -- that shows the flag can also show what it is a split of.
  (select count(*) from public.expense_voucher s
    where s.tenant_id = v.tenant_id and s.campus_id = v.campus_id and s.head_id = v.head_id
      and s.voucher_date = v.voucher_date and s.payee_key = v.payee_key
      and s.status <> 'rejected' and s.id <> v.id) as split_sibling_count,
  (select coalesce(sum(s.amount_paisa), 0) from public.expense_voucher s
    where s.tenant_id = v.tenant_id and s.campus_id = v.campus_id and s.head_id = v.head_id
      and s.voucher_date = v.voucher_date and s.payee_key = v.payee_key
      and s.status <> 'rejected') as split_group_total_paisa
from public.expense_voucher v
join public.campus c on c.id = v.campus_id
join public.expense_head h on h.id = v.head_id
left join public.app_user payer on payer.user_id = v.paid_by
left join public.app_user submitter on submitter.user_id = v.created_by;

revoke all on public.v_expense_voucher from public, anon;
grant select on public.v_expense_voucher to authenticated;

create or replace view public.v_expense_voucher_approval
with (security_invoker = true) as
select
  a.id,
  a.tenant_id,
  a.voucher_id,
  a.approver_id,
  u.full_name as approver_name,
  a.approver_role,
  a.decision,
  a.reason,
  -- host() rather than the raw inet: the netmask a /32 carries is noise on
  -- screen, and inet has no TypeScript mapping so the generated type would
  -- be `unknown`.
  host(a.request_ip) as request_ip,
  a.decided_at
from public.expense_voucher_approval a
left join public.app_user u on u.user_id = a.approver_id;

revoke all on public.v_expense_voucher_approval from public, anon;
grant select on public.v_expense_voucher_approval to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- provision_tenant: seed the heads a voucher needs to point at
-- ═══════════════════════════════════════════════════════════════════════

-- Re-emitted from 20260731550000 with one line added, the same way class
-- levels and message templates were wired in. The thresholds are NOT seeded
-- here — they hang off the campus trigger above, because create_campus()
-- makes campuses too.
create or replace function public.provision_tenant(p_slug text, p_legal_name text, p_owner_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if p_slug !~ '^[a-z0-9][a-z0-9-]{2,49}$' then
    raise exception 'TENANT_SLUG_INVALID' using errcode = '22023';
  end if;

  if exists (select 1 from public.tenant where lower(slug) = lower(p_slug)) then
    raise exception 'TENANT_SLUG_TAKEN' using errcode = '23505';
  end if;

  insert into public.tenant (slug, name, legal_name, status)
  values (p_slug, p_legal_name, p_legal_name, 'provisioning')
  returning id into v_tenant_id;

  perform public.seed_tenant_roles(v_tenant_id);
  perform public.seed_default_class_levels(v_tenant_id);
  perform public.seed_default_message_templates(v_tenant_id);
  perform public.seed_onboarding_progress(v_tenant_id);
  perform public.seed_default_expense_heads(v_tenant_id);

  insert into public.campus (tenant_id, code, name)
  values (v_tenant_id, 'MAIN', p_legal_name)
  returning id into v_campus_id;

  insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
  values (
    v_tenant_id,
    v_campus_id,
    to_char(current_date, 'YYYY') || '-' || to_char(current_date + interval '1 year', 'YY'),
    date_trunc('year', current_date)::date,
    (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
    true,
    'active'
  );

  insert into public.tenant_invitation (tenant_id, email, app_role)
  values (v_tenant_id, p_owner_email, 'owner');

  update public.tenant set status = 'active' where id = v_tenant_id;

  return v_tenant_id;
end;
$$;

-- Existing tenants get the same starting chart of heads.
select public.seed_default_expense_heads(t.id) from public.tenant t;
