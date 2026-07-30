-- FR-K05: concession scheme catalogue — the master data FR-K06 (award
-- workflow, not built here) will apply against.
--
-- Applicability is per fee head (applicable_head_ids), not global — the
-- Notes are explicit about why: "sibling discount on tuition" quietly
-- becoming a discount on transport and exam fees too is a real, recurring
-- way schools lose six figures a year, not a hypothetical edge case.
--
-- ck_concession_value_range is scoped to the SCHEME row only (value
-- non-negative, percentage capped at 100, max_value non-negative) — a
-- plain CHECK constraint can only ever validate columns on the same row.
-- The AC's "an award at 40% against a scheme with max_percentage 25 is
-- rejected at insert" is a cross-table comparison (an award's value
-- against ITS scheme's max_value) and cannot be a bare CHECK constraint;
-- enforcing it is concession_award's job in FR-K06, not built here.
--
-- Discount computation itself ("TUITION 5,000 at 10% = 50000 paisa,
-- TRANSPORT untouched") is also FR-K06/challan-generation territory —
-- this migration is the catalogue only, no award, no computation.

create type public.concession_calc_type as enum ('percentage', 'fixed_amount');

create table public.concession_scheme (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  code                    text not null,
  name_en                 text not null,
  name_ur                 text not null,
  category                text,
  calc_type               public.concession_calc_type not null,
  value                   numeric(10, 2) not null,
  max_value               numeric(10, 2),
  applicable_head_ids     uuid[] not null,
  approver_role           public.app_role not null default 'owner',
  default_validity_months smallint not null default 12,
  requires_document       boolean not null default false,
  is_active               boolean not null default true,
  created_by              uuid references public.app_user(user_id),
  created_at              timestamptz not null default now(),
  constraint ck_concession_value_range check (
    value >= 0
    and (calc_type <> 'percentage' or value <= 100)
    and (max_value is null or max_value >= 0)
    and (max_value is null or calc_type <> 'percentage' or max_value <= 100)
  ),
  -- array_length() of an empty array is NULL, not 0 — "NULL > 0" is
  -- itself NULL, which a CHECK constraint treats as passing, not
  -- violating. coalesce(...) is the whole fix.
  constraint ck_concession_applicable_heads_not_empty check (coalesce(array_length(applicable_head_ids, 1), 0) > 0)
);

create unique index concession_scheme_tenant_code_uq on public.concession_scheme (tenant_id, lower(code));
create index idx_concession_scheme_tenant_active on public.concession_scheme (tenant_id, is_active);

create trigger concession_scheme_audit after insert or update or delete on public.concession_scheme
  for each row execute function app.tg_audit_row();

create or replace function public.create_concession_scheme(
  p_code text, p_name_en text, p_name_ur text, p_calc_type public.concession_calc_type, p_value numeric,
  p_applicable_head_ids uuid[],
  p_category text default null,
  p_max_value numeric default null,
  p_approver_role public.app_role default 'owner',
  p_default_validity_months smallint default 12,
  p_requires_document boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_bad_head uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select h into v_bad_head from unnest(p_applicable_head_ids) as h
   where not exists (select 1 from public.fee_head where id = h and tenant_id = app.auth_tenant_id())
   limit 1;
  if v_bad_head is not null then
    raise exception 'FEE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.concession_scheme (
    tenant_id, code, name_en, name_ur, category, calc_type, value, max_value,
    applicable_head_ids, approver_role, default_validity_months, requires_document, created_by
  ) values (
    app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_category, p_calc_type, p_value, p_max_value,
    p_applicable_head_ids, p_approver_role, p_default_validity_months, p_requires_document, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_concession_scheme(
  text, text, text, public.concession_calc_type, numeric, uuid[], text, numeric, public.app_role, smallint, boolean
) from public, anon;
grant execute on function public.create_concession_scheme(
  text, text, text, public.concession_calc_type, numeric, uuid[], text, numeric, public.app_role, smallint, boolean
) to authenticated;

-- Deactivating narrows only what NEW awards may select — it must never
-- reach into concession_award (FR-K06) and touch an existing one, which
-- is exactly why this is a single column flip, not a cascading update.
create or replace function public.set_concession_scheme_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.concession_scheme set is_active = p_is_active where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CONCESSION_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.set_concession_scheme_active(uuid, boolean) from public, anon;
grant execute on function public.set_concession_scheme_active(uuid, boolean) to authenticated;

alter table public.concession_scheme enable row level security;

create policy concession_scheme_tenant_read on public.concession_scheme
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
