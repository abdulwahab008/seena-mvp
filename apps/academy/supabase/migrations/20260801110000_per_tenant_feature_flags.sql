-- FR-A17: per-tenant feature flags.
--
-- Resolution order is tenant override → plan default → platform default, and
-- it is evaluated live in Postgres on every call. Nothing about a flag rides
-- in the JWT, deliberately:
--   * AC2 ("a Super Admin enables a flag; the Owner reloads within 60s and
--     the feature appears") is then satisfied at 0s with no token refresh and
--     no re-login, rather than requiring a claims_version bump and a
--     TOKEN_EPOCH_STALE round trip.
--   * A flag is not identity. Putting it in the token would mean every
--     toggle invalidates every session in the tenant (FR-A13's epoch), which
--     is a much worse trade than one extra indexed lookup per statement.
-- So, explicitly: no claims_version bumping here. The only authorization
-- input that changes is read from the database at the point of use.
--
-- ── Why a bespoke table set and not tenant_setting ──────────────────────
-- public.tenant_setting (foundation.sql) is the established generic
-- tenant-level key/value store and was the first thing considered. It cannot
-- express this: resolution has three levels, and the middle one (the plan
-- default) is not tenant-scoped data at all — it is platform data shared by
-- every tenant on that plan. Storing a resolved boolean per tenant in
-- tenant_setting would mean re-writing every tenant's row whenever a plan
-- changes, and would lose the distinction between "explicitly overridden"
-- and "inherited", which is exactly what an override table is for.
-- tenant_feature_override IS the tenant-level key/value store here; it is
-- just typed and foreign-keyed instead of jsonb.
--
-- ── Enforcement ────────────────────────────────────────────────────────
-- Two layers, because either alone is a hole:
--   1. A RESTRICTIVE RLS policy per gated table. Restrictive (not permissive)
--      because permissive policies OR together — adding a permissive
--      "feature is on" policy beside the existing ones would *widen* access,
--      not gate it. This covers SELECT (AC4: rows are hidden, never deleted,
--      and reappear when re-enabled) and direct PostgREST writes (AC3).
--   2. A BEFORE INSERT/UPDATE trigger per gated table. RLS does not run for
--      a SECURITY DEFINER function owned by postgres, and this codebase
--      writes almost everything through such functions — create_homework,
--      submit_expense_voucher and friends would otherwise stay callable with
--      the module switched off, which is the "hidden button" failure mode
--      the FR's Notes are about. A trigger fires on every write path.
-- The trigger resolves the flag from the *row's* tenant_id rather than the
-- caller's claim, so it is correct no matter who is writing.
--
-- SQLSTATE 42501 (not class 55) so PostgREST returns 403 FEATURE_DISABLED
-- with a readable body rather than a generic 500.

-- ── Tables ──────────────────────────────────────────────────────────────

create table public.feature_flag (
  code            text primary key,
  label           text not null,
  description     text,
  default_enabled boolean not null default false,
  is_beta         boolean not null default false
);

create table public.plan (
  code text primary key,
  name text not null,
  rank smallint not null default 0
);

create table public.plan_feature (
  plan_code    text not null references public.plan(code) on delete cascade,
  feature_code text not null references public.feature_flag(code) on delete cascade,
  enabled      boolean not null,
  primary key (plan_code, feature_code)
);

create table public.tenant_subscription (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  plan_code  text not null references public.plan(code),
  valid_from date not null default current_date,
  valid_to   date,
  created_at timestamptz not null default now(),
  constraint tenant_subscription_range check (valid_to is null or valid_to >= valid_from)
);

-- One live subscription per tenant at a time; history is kept by closing the
-- previous row's valid_to rather than deleting it.
create unique index tenant_subscription_current_uniq
  on public.tenant_subscription (tenant_id) where valid_to is null;
create index tenant_subscription_tenant_idx on public.tenant_subscription (tenant_id, valid_from desc);

create table public.tenant_feature_override (
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  feature_code text not null references public.feature_flag(code) on delete cascade,
  enabled      boolean not null,
  set_by       uuid references auth.users(id),
  set_at       timestamptz not null default now(),
  primary key (tenant_id, feature_code)
);

-- ── Catalogue ───────────────────────────────────────────────────────────
--
-- Every module that already ships gets default_enabled = true, so a tenant
-- with no subscription row and no override behaves exactly as it did before
-- this migration. A flag only ever takes something away once somebody
-- deliberately puts them on a plan that withholds it.
insert into public.feature_flag (code, label, description, default_enabled, is_beta) values
  ('module.homework',           'Homework',            'Set, publish and track homework.',            true,  false),
  ('module.expenses',           'Expenses',            'Expense heads, vouchers and approvals.',      true,  false),
  ('module.transport',          'Transport',           'Student transport routes and assignments.',   true,  false),
  ('exams.ai_paper_generation', 'AI paper generation', 'Draft exam papers from the question bank.',   false, true);

insert into public.plan (code, name, rank) values
  ('basic',    'Basic',    1),
  ('standard', 'Standard', 2),
  ('premium',  'Premium',  3);

insert into public.plan_feature (plan_code, feature_code, enabled) values
  ('basic',    'module.homework',           true),
  ('basic',    'module.expenses',           false),
  ('basic',    'module.transport',          false),
  ('basic',    'exams.ai_paper_generation', false),
  ('standard', 'module.homework',           true),
  ('standard', 'module.expenses',           true),
  ('standard', 'module.transport',          true),
  ('standard', 'exams.ai_paper_generation', false),
  ('premium',  'module.homework',           true),
  ('premium',  'module.expenses',           true),
  ('premium',  'module.transport',          true),
  ('premium',  'exams.ai_paper_generation', true);

-- ── Resolution ──────────────────────────────────────────────────────────

create or replace function app.feature_enabled_for(p_tenant_id uuid, p_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select o.enabled
       from public.tenant_feature_override o
      where o.tenant_id = p_tenant_id and o.feature_code = p_code),
    (select pf.enabled
       from public.tenant_subscription ts
       join public.plan_feature pf on pf.plan_code = ts.plan_code
      where ts.tenant_id = p_tenant_id
        and pf.feature_code = p_code
        and ts.valid_from <= current_date
        and (ts.valid_to is null or ts.valid_to >= current_date)
      order by ts.valid_from desc
      limit 1),
    (select f.default_enabled from public.feature_flag f where f.code = p_code),
    -- A code that is in no catalogue at all is off: a typo in a gate must
    -- close the module, not silently open it.
    false
  );
$$;

create or replace function app.feature_enabled(p_code text)
returns boolean
language sql
stable
as $$
  select app.feature_enabled_for(app.auth_tenant_id(), p_code);
$$;

create or replace function app.assert_feature_enabled(p_code text)
returns void
language plpgsql
stable
as $$
begin
  if not app.feature_enabled(p_code) then
    raise exception 'FEATURE_DISABLED' using errcode = '42501', detail = p_code;
  end if;
end;
$$;

grant execute on function app.feature_enabled_for(uuid, text) to authenticated;
grant execute on function app.feature_enabled(text) to authenticated;
grant execute on function app.assert_feature_enabled(text) to authenticated;

-- The whole resolved set, for the session bootstrap the requirement asks for
-- ("shall return the resolved flag set with every session bootstrap").
create or replace function public.resolved_features(p_tenant_id uuid default null)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  -- A caller may only resolve their own tenant. p_tenant_id is accepted
  -- because the FR names the signature, but a Super Admin is the only one
  -- who can point it anywhere else — otherwise it is pinned to the claim.
  with target as (
    select case
             when p_tenant_id is null then app.auth_tenant_id()
             when app.auth_role() = 'super_admin' then p_tenant_id
             when p_tenant_id = app.auth_tenant_id() then p_tenant_id
             else null
           end as tenant_id
  )
  select coalesce(
    jsonb_object_agg(f.code, app.feature_enabled_for(t.tenant_id, f.code)),
    '{}'::jsonb
  )
    from public.feature_flag f cross join target t
   where t.tenant_id is not null;
$$;

revoke execute on function public.resolved_features(uuid) from public, anon;
grant execute on function public.resolved_features(uuid) to authenticated;

-- ── Toggling ────────────────────────────────────────────────────────────
--
-- Super Admin only, per AC2: enabling a module for a tenant is a commercial
-- act (it is what the plan is for), so the Owner it affects is not the one
-- who may do it. An Owner reads their resolved set and sees the result.
-- p_enabled defaults to null (= clear the override) from the outset: adding
-- the default later would create a distinct overload.
create or replace function public.set_tenant_feature(
  p_tenant_id uuid,
  p_code      text,
  p_enabled   boolean default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() <> 'super_admin' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (select 1 from public.feature_flag where code = p_code) then
    raise exception 'FEATURE_UNKNOWN' using errcode = '23503', detail = p_code;
  end if;

  if not exists (select 1 from public.tenant where id = p_tenant_id) then
    raise exception 'TENANT_NOT_FOUND' using errcode = '23503';
  end if;

  -- p_enabled null clears the override and lets the plan/platform default
  -- take over again. It never touches the module's data — see AC4.
  if p_enabled is null then
    delete from public.tenant_feature_override
     where tenant_id = p_tenant_id and feature_code = p_code;
    return;
  end if;

  insert into public.tenant_feature_override (tenant_id, feature_code, enabled, set_by, set_at)
  values (p_tenant_id, p_code, p_enabled, (select auth.uid()), now())
  on conflict (tenant_id, feature_code)
    do update set enabled = excluded.enabled, set_by = excluded.set_by, set_at = excluded.set_at;
end;
$$;

create or replace function public.set_tenant_plan(p_tenant_id uuid, p_plan_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() <> 'super_admin' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (select 1 from public.plan where code = p_plan_code) then
    raise exception 'PLAN_UNKNOWN' using errcode = '23503', detail = p_plan_code;
  end if;

  update public.tenant_subscription
     set valid_to = current_date
   where tenant_id = p_tenant_id and valid_to is null;

  insert into public.tenant_subscription (tenant_id, plan_code)
  values (p_tenant_id, p_plan_code);
end;
$$;

revoke execute on function public.set_tenant_feature(uuid, text, boolean) from public, anon;
revoke execute on function public.set_tenant_plan(uuid, text) from public, anon;
grant execute on function public.set_tenant_feature(uuid, text, boolean) to authenticated;
grant execute on function public.set_tenant_plan(uuid, text) to authenticated;

-- ── Enforcement layer 2: the write trigger ──────────────────────────────

create or replace function app.tg_require_feature()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code      text := tg_argv[0];
  v_tenant_id uuid := coalesce((to_jsonb(new) ->> 'tenant_id')::uuid, app.auth_tenant_id());
begin
  if not app.feature_enabled_for(v_tenant_id, v_code) then
    raise exception 'FEATURE_DISABLED' using errcode = '42501', detail = v_code;
  end if;
  return new;
end;
$$;

-- ── Gated modules ───────────────────────────────────────────────────────
--
-- Only tables that actually exist are gated. 'module.transport' is the FR's
-- own example; in this codebase transport is public.student_transport (a
-- student-profile assignment), and there is no Transport nav item to hide —
-- the nav-level half of AC1 is exercised against Homework and Expenses,
-- which do have nav entries. 'exams.ai_paper_generation' is catalogued (AC2
-- names it) but gates nothing yet: there is no paper-generation module in
-- this codebase to gate, and inventing an empty one to hang a flag on would
-- be worse than saying so.

alter table public.homework enable row level security;
create policy homework_feature_gate on public.homework
  as restrictive for all to authenticated
  using (app.feature_enabled('module.homework'))
  with check (app.feature_enabled('module.homework'));
create trigger homework_require_feature
  before insert or update on public.homework
  for each row execute function app.tg_require_feature('module.homework');

create policy expense_head_feature_gate on public.expense_head
  as restrictive for all to authenticated
  using (app.feature_enabled('module.expenses'))
  with check (app.feature_enabled('module.expenses'));
create trigger expense_head_require_feature
  before insert or update on public.expense_head
  for each row execute function app.tg_require_feature('module.expenses');

create policy expense_voucher_feature_gate on public.expense_voucher
  as restrictive for all to authenticated
  using (app.feature_enabled('module.expenses'))
  with check (app.feature_enabled('module.expenses'));
create trigger expense_voucher_require_feature
  before insert or update on public.expense_voucher
  for each row execute function app.tg_require_feature('module.expenses');

create policy student_transport_feature_gate on public.student_transport
  as restrictive for all to authenticated
  using (app.feature_enabled('module.transport'))
  with check (app.feature_enabled('module.transport'));
create trigger student_transport_require_feature
  before insert or update on public.student_transport
  for each row execute function app.tg_require_feature('module.transport');

-- ── RLS on the flag store itself ────────────────────────────────────────

alter table public.feature_flag enable row level security;
alter table public.plan enable row level security;
alter table public.plan_feature enable row level security;
alter table public.tenant_subscription enable row level security;
alter table public.tenant_feature_override enable row level security;

-- The catalogue and the plan matrix are platform data, readable by anyone
-- signed in (an Owner has to be able to see what their plan does and does
-- not include). Writes are service_role only — no policy at all.
create policy feature_flag_read_all on public.feature_flag
  for select to authenticated using (true);
create policy plan_read_all on public.plan
  for select to authenticated using (true);
create policy plan_feature_read_all on public.plan_feature
  for select to authenticated using (true);

-- A tenant sees its own subscription and its own overrides; a Super Admin
-- sees every tenant's, because the console they toggle from is cross-tenant.
create policy tenant_subscription_scope on public.tenant_subscription
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() or app.auth_role() = 'super_admin');

create policy tenant_feature_override_scope on public.tenant_feature_override
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() or app.auth_role() = 'super_admin');
