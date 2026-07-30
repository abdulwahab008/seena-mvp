-- FR-K02: fee structure per class per session.
--
-- Accounting-specific care:
--   * amount_paisa is bigint, never numeric or float. A 3-way sibling
--     split of a rupee amount must not lose a paisa across the challan,
--     ledger and receipt — floating point is how that happens silently.
--     Clients send/display rupees; every paisa<->rupee conversion happens
--     at the UI boundary, never inside a stored value or a calculation.
--   * A structure is draft, then published-once, then eventually
--     superseded — never edited after publish. publish_fee_structure()
--     is the one-way gate: it also supersedes whatever structure was
--     previously 'published' for the same campus+session, since only one
--     structure can be authoritative for billing at a time.
--   * billing_month_mask is a 12-bit mask, bit (month - 1) set means "this
--     head bills in that calendar month" (Jan = bit 0 ... Dec = bit 11).
--     Storing this explicitly is the whole point of K02's own Notes: a
--     head marked "quarterly" means nothing to a challan generator unless
--     the system also knows WHICH four months.
--
-- is_mandatory is added to fee_head here, not in FR-K01's migration —
-- K01's own AC never mentions it; it only exists to let
-- publish_fee_structure() check "does every active class have a line for
-- every mandatory head", which is entirely K02's concern.

alter table public.fee_head add column is_mandatory boolean not null default false;

create or replace function public.seed_default_fee_heads(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.fee_head (tenant_id, code, name_en, name_ur, is_refundable, is_mandatory, default_frequency, created_by) values
    (p_tenant_id, 'TUITION',          'Tuition Fee',      'فیس تعلیم',        false, true,  'monthly',  auth.uid()),
    (p_tenant_id, 'ADMISSION',        'Admission Fee',    'داخلہ فیس',        false, false, 'one_time', auth.uid()),
    (p_tenant_id, 'EXAM',             'Examination Fee',  'امتحانی فیس',      false, false, 'quarterly', auth.uid()),
    (p_tenant_id, 'TRANSPORT',        'Transport Fee',    'ٹرانسپورٹ فیس',    false, false, 'monthly',  auth.uid()),
    (p_tenant_id, 'LAB',              'Laboratory Fee',   'لیبارٹری فیس',     false, false, 'quarterly', auth.uid()),
    (p_tenant_id, 'SPORTS',           'Sports Fee',       'کھیل فیس',         false, false, 'annual',   auth.uid()),
    (p_tenant_id, 'SECURITY_DEPOSIT', 'Security Deposit', 'ضمانتی رقم',       true,  false, 'one_time', auth.uid()),
    (p_tenant_id, 'ANNUAL',           'Annual Fund',      'سالانہ فنڈ',       false, false, 'annual',   auth.uid());
end;
$$;

-- A new arg (p_is_mandatory) means create-or-replace would add a second
-- overload instead of replacing the FR-K01 original — drop it first so
-- only one create_fee_head exists, same reasoning as create_section's own
-- widening in the enrolment migration.
drop function if exists public.create_fee_head(text, text, text, boolean, boolean, text, public.fee_frequency);

create or replace function public.create_fee_head(
  p_code text, p_name_en text, p_name_ur text,
  p_is_refundable boolean default false,
  p_carry_forward_on_arrears boolean default true,
  p_gl_code text default null,
  p_default_frequency public.fee_frequency default 'monthly',
  p_is_mandatory boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.fee_head (
    tenant_id, code, name_en, name_ur, is_refundable, carry_forward_on_arrears, gl_code, default_frequency, is_mandatory, created_by
  )
  values (
    app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_is_refundable, p_carry_forward_on_arrears, p_gl_code, p_default_frequency, p_is_mandatory, auth.uid()
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_fee_head(text, text, text, boolean, boolean, text, public.fee_frequency, boolean) from public, anon;
grant execute on function public.create_fee_head(text, text, text, boolean, boolean, text, public.fee_frequency, boolean) to authenticated;

-- ── fee_structure / fee_structure_line ──────────────────────────────────

create type public.fee_structure_status as enum ('draft', 'published', 'superseded');

create table public.fee_structure (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  version_no      int not null default 1,
  status          public.fee_structure_status not null default 'draft',
  effective_from  date not null default current_date,
  published_by    uuid references public.app_user(user_id),
  published_at    timestamptz,
  created_by      uuid references public.app_user(user_id),
  created_at      timestamptz not null default now()
);

create index idx_fee_structure_campus_session_status on public.fee_structure (campus_id, session_id, status);

create trigger fee_structure_audit after insert or update or delete on public.fee_structure
  for each row execute function app.tg_audit_row();

create table public.fee_structure_line (
  id                  uuid primary key default gen_random_uuid(),
  structure_id        uuid not null references public.fee_structure(id) on delete cascade,
  class_id            uuid not null references public.class_level(id),
  group_code          text,
  fee_head_id         uuid not null references public.fee_head(id),
  amount_paisa        bigint not null check (amount_paisa >= 0),
  frequency           public.fee_frequency not null,
  billing_month_mask  smallint not null default 4095,
  created_at          timestamptz not null default now()
);

-- coalesce(group_code, '') so a class-wide line (no group) and a
-- group-specific line for the same head are both representable, and a
-- second class-wide line for the same head is still rejected.
create unique index fee_structure_line_uq on public.fee_structure_line (
  structure_id, class_id, coalesce(group_code, ''), fee_head_id
);

create or replace function public.create_draft_structure(p_campus_id uuid, p_session_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.fee_structure (tenant_id, campus_id, session_id, created_by)
  values (app.auth_tenant_id(), p_campus_id, p_session_id, auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_draft_structure(uuid, uuid) from public, anon;
grant execute on function public.create_draft_structure(uuid, uuid) to authenticated;

create or replace function public.add_structure_line(
  p_structure_id uuid, p_class_id uuid, p_fee_head_id uuid, p_amount_paisa bigint, p_frequency public.fee_frequency,
  p_group_code text default null, p_billing_month_mask smallint default 4095
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.fee_structure_status;
  v_id     uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select status into v_status from public.fee_structure where id = p_structure_id and tenant_id = app.auth_tenant_id();
  if v_status is null then
    raise exception 'STRUCTURE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'STRUCTURE_NOT_DRAFT' using errcode = '55000';
  end if;

  insert into public.fee_structure_line (structure_id, class_id, group_code, fee_head_id, amount_paisa, frequency, billing_month_mask)
  values (p_structure_id, p_class_id, p_group_code, p_fee_head_id, p_amount_paisa, p_frequency, p_billing_month_mask)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.add_structure_line(uuid, uuid, uuid, bigint, public.fee_frequency, text, smallint) from public, anon;
grant execute on function public.add_structure_line(uuid, uuid, uuid, bigint, public.fee_frequency, text, smallint) to authenticated;

-- The one-way gate: draft -> published, blocked unless every active class
-- level has at least one line for every mandatory fee head (group-aware
-- coverage — "does Pre-Medical need its own LAB line" — is a real, later
-- refinement; today's check is "does this class have a line for this
-- head at all", which is exactly what the AC's TUITION-missing-for-
-- class-6 example needs).
create or replace function public.publish_fee_structure(p_structure_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_structure public.fee_structure%rowtype;
  v_gaps      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_structure from public.fee_structure where id = p_structure_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STRUCTURE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_structure.status <> 'draft' then
    raise exception 'STRUCTURE_NOT_DRAFT' using errcode = '55000';
  end if;

  select string_agg(cl.name_en || '/' || fh.code, ', ')
    into v_gaps
    from public.class_level cl
    cross join public.fee_head fh
   where cl.tenant_id = app.auth_tenant_id() and cl.is_active
     and fh.tenant_id = app.auth_tenant_id() and fh.is_mandatory
     and not exists (
       select 1 from public.fee_structure_line l
        where l.structure_id = p_structure_id and l.class_id = cl.id and l.fee_head_id = fh.id
     );
  if v_gaps is not null then
    raise exception 'MANDATORY_HEAD_COVERAGE_GAP' using errcode = '55000', detail = v_gaps;
  end if;

  update public.fee_structure
     set status = 'superseded'
   where campus_id = v_structure.campus_id and session_id = v_structure.session_id and status = 'published';

  update public.fee_structure
     set status = 'published', published_by = auth.uid(), published_at = now()
   where id = p_structure_id;
end;
$$;

revoke execute on function public.publish_fee_structure(uuid) from public, anon;
grant execute on function public.publish_fee_structure(uuid) to authenticated;

alter table public.fee_structure enable row level security;
alter table public.fee_structure_line enable row level security;

create policy fee_structure_campus_scope on public.fee_structure
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy fee_structure_line_read on public.fee_structure_line
  for select to authenticated
  using (
    structure_id in (
      select id from public.fee_structure
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
