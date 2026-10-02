-- FR-E01 (class level catalogue) and FR-B01 (enquiry capture). E01 ships
-- first in this same migration because B01's class_applied_id needs
-- somewhere real to point at — Module E (Academic Setup) doesn't exist yet
-- otherwise.
--
-- Scope cuts:
--   * class_level has no DELETE path at all (no grant, no policy) rather
--     than the AC's conditional "blocked only when sections reference it" —
--     section (FR-E02) doesn't exist yet to check against. is_active=false
--     is the universal path for now, which is stricter than required but
--     never permits the bug the AC is actually guarding against. Swap the
--     trigger for a real usage check once E02 ships.
--   * admission_enquiry.referrer_student_id has no FK — student (Module C)
--     doesn't exist yet. Nullable, unenforced until then.
--   * This migration covers enquiry CREATION only. Status transitions
--     (lost/converted), follow-up tasks and the overdue worklist are FR-B04,
--     not built this batch.

-- ── E01: class_level ───────────────────────────────────────────────────

create table public.class_level (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  code        text not null,
  name_en     text not null,
  name_ur     text,
  ordinal     smallint not null,
  board_stage text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create unique index uq_class_level_tenant_code on public.class_level (tenant_id, code);
-- Deferrable: swap_class_level_ordinals() below needs to hold two rows'
-- ordinals in an intermediate, momentarily-colliding state within one
-- transaction.
alter table public.class_level
  add constraint uq_class_level_tenant_ordinal unique (tenant_id, ordinal) deferrable initially immediate;
create index idx_class_level_tenant_ordinal on public.class_level (tenant_id, ordinal);

create trigger class_level_audit after insert or update or delete on public.class_level
  for each row execute function app.tg_audit_row();

create or replace function public.seed_default_class_levels(p_tenant_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.class_level (tenant_id, code, name_en, ordinal, board_stage) values
    (p_tenant_id, 'NUR', 'Nursery',   0,  'pre_primary'),
    (p_tenant_id, 'KG',  'Kindergarten', 1, 'pre_primary'),
    (p_tenant_id, '1',   'Class 1',   2,  'primary'),
    (p_tenant_id, '2',   'Class 2',   3,  'primary'),
    (p_tenant_id, '3',   'Class 3',   4,  'primary'),
    (p_tenant_id, '4',   'Class 4',   5,  'primary'),
    (p_tenant_id, '5',   'Class 5',   6,  'primary'),
    (p_tenant_id, '6',   'Class 6',   7,  'middle'),
    (p_tenant_id, '7',   'Class 7',   8,  'middle'),
    (p_tenant_id, '8',   'Class 8',   9,  'middle'),
    (p_tenant_id, '9',   'Class 9',   10, 'secondary'),
    (p_tenant_id, '10',  'Class 10',  11, 'secondary'),
    (p_tenant_id, '11',  'Class 11',  12, 'higher_secondary'),
    (p_tenant_id, '12',  'Class 12',  13, 'higher_secondary');
$$;

revoke execute on function public.seed_default_class_levels(uuid) from public, anon, authenticated;
grant execute on function public.seed_default_class_levels(uuid) to service_role;

create or replace function public.create_class_level(
  p_code text, p_name_en text, p_name_ur text, p_ordinal smallint, p_board_stage text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.class_level (tenant_id, code, name_en, name_ur, ordinal, board_stage)
  values (app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_ordinal, p_board_stage)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_class_level(text, text, text, smallint, text) from public, anon;
grant execute on function public.create_class_level(text, text, text, smallint, text) to authenticated;

create or replace function public.set_class_level_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.class_level set is_active = p_is_active
   where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.set_class_level_active(uuid, boolean) from public, anon;
grant execute on function public.set_class_level_active(uuid, boolean) to authenticated;

-- Ordinal, not code, drives the promotion path — there is no separate
-- cached promotion sequence to go stale, so swapping ordinals here *is*
-- recomputing the promotion path, in the same transaction, for free.
create or replace function public.swap_class_level_ordinals(p_id_a uuid, p_id_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_a uuid;
  v_tenant_b uuid;
  v_ord_a    smallint;
  v_ord_b    smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, ordinal into v_tenant_a, v_ord_a from public.class_level where id = p_id_a;
  select tenant_id, ordinal into v_tenant_b, v_ord_b from public.class_level where id = p_id_b;
  if v_tenant_a is null or v_tenant_b is null or v_tenant_a <> v_tenant_b then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_a <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  set constraints public.uq_class_level_tenant_ordinal deferred;
  update public.class_level set ordinal = v_ord_b where id = p_id_a;
  update public.class_level set ordinal = v_ord_a where id = p_id_b;
end;
$$;

revoke execute on function public.swap_class_level_ordinals(uuid, uuid) from public, anon;
grant execute on function public.swap_class_level_ordinals(uuid, uuid) to authenticated;

alter table public.class_level enable row level security;

create policy class_level_tenant_read on public.class_level
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- provision_tenant (FR-A01) now also seeds the class level catalogue.
create or replace function public.provision_tenant(
  p_slug        text,
  p_legal_name  text,
  p_owner_email text
)
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

revoke execute on function public.provision_tenant(text, text, text) from public, anon, authenticated;
grant execute on function public.provision_tenant(text, text, text) to service_role;

-- ── B01: admission_enquiry ─────────────────────────────────────────────

create type public.enquiry_source as enum ('walk_in', 'phone', 'web', 'referral', 'other');
create type public.enquiry_status as enum ('open', 'converted', 'lost');

create table public.admission_enquiry (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  session_id          uuid not null references public.academic_session(id),
  enquiry_no          text,
  child_name          text not null,
  child_name_ur       text,
  dob                 date not null,
  class_applied_id    uuid not null references public.class_level(id),
  parent_name         text not null,
  parent_cnic         text,
  phone_e164          text not null,
  whatsapp_opt_in     boolean not null default false,
  source              public.enquiry_source not null,
  referrer_student_id uuid, -- no FK yet: student (Module C) doesn't exist
  referrer_name       text,
  status              public.enquiry_status not null default 'open',
  assigned_to         uuid references public.app_user(user_id),
  age_override_reason text,
  created_at          timestamptz not null default now()
);

create index idx_enquiry_phone on public.admission_enquiry (tenant_id, phone_e164);
create index idx_enquiry_campus_session_status on public.admission_enquiry (campus_id, session_id, status);

create table public.enquiry_no_counter (
  campus_id  uuid not null references public.campus(id) on delete cascade,
  session_id uuid not null references public.academic_session(id) on delete cascade,
  next_seq   int not null default 1,
  primary key (campus_id, session_id)
);

create or replace function public.fn_next_enquiry_no(p_campus_id uuid, p_session_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_seq         int;
  v_campus_code text;
  v_year        text;
begin
  insert into public.enquiry_no_counter (campus_id, session_id, next_seq)
  values (p_campus_id, p_session_id, 2)
  on conflict (campus_id, session_id) do update set next_seq = public.enquiry_no_counter.next_seq + 1
  returning next_seq - 1 into v_seq;

  select code into v_campus_code from public.campus where id = p_campus_id;
  select to_char(starts_on, 'YYYY') into v_year from public.academic_session where id = p_session_id;

  return v_campus_code || '-' || v_year || '-' || lpad(v_seq::text, 5, '0');
end;
$$;

revoke execute on function public.fn_next_enquiry_no(uuid, uuid) from public, anon, authenticated;
grant execute on function public.fn_next_enquiry_no(uuid, uuid) to service_role;

create or replace function app.tg_enquiry_no_biu()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.enquiry_no := public.fn_next_enquiry_no(new.campus_id, new.session_id);
  elsif new.enquiry_no is distinct from old.enquiry_no then
    raise exception 'ENQUIRY_NO_IMMUTABLE' using errcode = '42501';
  end if;
  return new;
end;
$$;

create trigger trg_enquiry_no_biu before insert or update on public.admission_enquiry
  for each row execute function app.tg_enquiry_no_biu();

create trigger admission_enquiry_audit after insert or update or delete on public.admission_enquiry
  for each row execute function app.tg_audit_row();

-- Required params first, then everything nullable/optional — PL/pgSQL
-- requires defaulted params to trail, and callers (supabase-js .rpc(), and
-- named-notation in pgTAP) pass everything by name anyway so declaration
-- order otherwise doesn't matter.
create or replace function public.create_enquiry(
  p_campus_id           uuid,
  p_session_id          uuid,
  p_child_name          text,
  p_dob                 date,
  p_class_applied_id    uuid,
  p_parent_name         text,
  p_phone               text,
  p_whatsapp_opt_in     boolean,
  p_source              public.enquiry_source,
  p_child_name_ur       text default null,
  p_parent_cnic         text default null,
  p_referrer_name       text default null,
  p_age_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id             uuid;
  v_phone          text;
  v_class_ordinal  smallint;
  v_session_year   int;
  v_ref_date       date;
  v_age_months     int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_source = 'referral' and (p_referrer_name is null or btrim(p_referrer_name) = '') then
    raise exception 'Referrer required for referral enquiries' using errcode = '23514';
  end if;

  v_phone := public.normalize_pk_phone(p_phone);
  if v_phone is null then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;

  select ordinal into v_class_ordinal from public.class_level where id = p_class_applied_id;
  if v_class_ordinal is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The 2y6m-by-1-April gate is Nursery-specific (ordinal 0) — older
  -- classes have their own admission-test/prior-schooling gates, not an age
  -- floor computed here.
  if v_class_ordinal = 0 then
    select starts_on into v_ref_date from public.academic_session where id = p_session_id;
    v_session_year := extract(year from v_ref_date);
    v_ref_date := make_date(v_session_year, 4, 1);
    v_age_months := extract(year from age(v_ref_date, p_dob))::int * 12 + extract(month from age(v_ref_date, p_dob))::int;
    if v_age_months < 30 and (p_age_override_reason is null or btrim(p_age_override_reason) = '') then
      raise exception 'AGE_BELOW_MINIMUM_NEEDS_OVERRIDE' using errcode = '23514';
    end if;
  end if;

  insert into public.admission_enquiry (
    tenant_id, campus_id, session_id, child_name, child_name_ur, dob, class_applied_id,
    parent_name, parent_cnic, phone_e164, whatsapp_opt_in, source, referrer_name,
    assigned_to, age_override_reason
  ) values (
    app.auth_tenant_id(), p_campus_id, p_session_id, p_child_name, p_child_name_ur, p_dob, p_class_applied_id,
    p_parent_name, p_parent_cnic, v_phone, p_whatsapp_opt_in, p_source, p_referrer_name,
    auth.uid(), p_age_override_reason
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_enquiry(
  uuid, uuid, text, date, uuid, text, text, boolean, public.enquiry_source, text, text, text, text
) from public, anon;
grant execute on function public.create_enquiry(
  uuid, uuid, text, date, uuid, text, text, boolean, public.enquiry_source, text, text, text, text
) to authenticated;

alter table public.admission_enquiry enable row level security;
alter table public.enquiry_no_counter enable row level security;

create policy enquiry_campus_scope on public.admission_enquiry
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
