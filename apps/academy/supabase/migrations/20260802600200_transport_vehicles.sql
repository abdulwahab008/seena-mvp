-- FR-P02: vehicle register with a hard document-expiry block.
--
-- A vehicle whose fitness certificate (or any other required document) has
-- expired cannot be assigned to a trip. The block is enforced in the database
-- by app.fn_vehicle_assert(), which every assignment path calls, and is hard:
-- the only way past it is a Principal's named override (a row that records who,
-- when, the dates it covers and why; the audit trigger also writes it to
-- audit_log). A dismissible warning would be clicked through every morning.
--
-- Which documents are required is a tenant setting (transport.required_documents,
-- default fitness, token_tax, insurance). Token tax can be waived for contracted
-- vehicles with transport.token_tax_mandatory_for_contracted = false. A document
-- row with mandatory = false is ignored by the check. A daily digest lists
-- everything expiring within 30 days to the Transport Manager and Principal as
-- one message each, and never repeats the same document within 7 days.
--
-- Scope notes: there is no asset register in this schema yet, so asset_id is a
-- plain nullable uuid with no foreign key.

create type public.transport_fuel as enum ('petrol', 'diesel', 'cng', 'lpg', 'hybrid', 'electric');
create type public.transport_ownership as enum ('owned', 'contracted');
create type public.transport_doc_type as enum ('permit', 'fitness', 'token_tax', 'insurance');

create table public.transport_vehicle (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  reg_no        text not null check (char_length(btrim(reg_no)) between 3 and 20),
  make          text check (make is null or char_length(make) <= 60),
  model         text check (model is null or char_length(model) <= 60),
  seat_capacity int not null check (seat_capacity between 1 and 100),
  fuel          public.transport_fuel not null default 'diesel',
  ownership     public.transport_ownership not null default 'owned',
  asset_id      uuid,
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint uq_vehicle_reg unique (tenant_id, reg_no)
);
create index idx_vehicle_scope on public.transport_vehicle (tenant_id, campus_id);

create table public.transport_vehicle_document (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  vehicle_id uuid not null references public.transport_vehicle(id) on delete cascade,
  doc_type   public.transport_doc_type not null,
  doc_no     text check (doc_no is null or char_length(doc_no) <= 60),
  issued_on  date,
  expires_on date not null,
  file_path  text,
  mandatory  boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  constraint chk_doc_dates check (issued_on is null or expires_on >= issued_on)
);
create index idx_vehicle_doc_vehicle on public.transport_vehicle_document (vehicle_id, doc_type, expires_on desc);
create index idx_vehicle_doc_scope on public.transport_vehicle_document (tenant_id, campus_id, expires_on);

-- A Principal's named override of the block, covering a date span.
create table public.transport_vehicle_override (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  vehicle_id  uuid not null references public.transport_vehicle(id) on delete cascade,
  valid_from  date not null,
  valid_to    date not null,
  reason      text not null check (char_length(btrim(reason)) >= 10),
  approved_by uuid not null references auth.users(id),
  approved_at timestamptz not null default now(),
  constraint chk_override_span check (valid_to >= valid_from)
);
create index idx_vehicle_override on public.transport_vehicle_override (vehicle_id, valid_from, valid_to);
create index idx_vehicle_override_scope on public.transport_vehicle_override (tenant_id, campus_id);

-- Which documents have already been put in a digest, and when.
create table public.transport_document_alert (
  document_id uuid primary key references public.transport_vehicle_document(id) on delete cascade,
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  last_sent_on date not null
);
create index idx_doc_alert_tenant on public.transport_document_alert (tenant_id);

create trigger transport_vehicle_audit after insert or update or delete on public.transport_vehicle
  for each row execute function app.tg_audit_row();
create trigger transport_vehicle_document_audit after insert or update or delete on public.transport_vehicle_document
  for each row execute function app.tg_audit_row();
create trigger transport_vehicle_override_audit after insert or update or delete on public.transport_vehicle_override
  for each row execute function app.tg_audit_row();

alter table public.transport_vehicle enable row level security;
alter table public.transport_vehicle_document enable row level security;
alter table public.transport_vehicle_override enable row level security;
alter table public.transport_document_alert enable row level security;
create policy transport_vehicle_campus_scope on public.transport_vehicle for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() not in ('parent', 'student'));
create policy transport_vehicle_document_campus_scope on public.transport_vehicle_document for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'));
create policy transport_vehicle_override_campus_scope on public.transport_vehicle_override for select to authenticated
  using (app.fn_campus_scope(tenant_id, campus_id) and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'));
-- transport_document_alert: no policy, service role only.

-- ── Tenant settings the block reads ─────────────────────────────────────────
create or replace function app.fn_transport_setting(p_tenant uuid, p_key text, p_default jsonb)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select value from public.tenant_setting where tenant_id = p_tenant and key = p_key), p_default);
$$;
revoke execute on function app.fn_transport_setting(uuid, text, jsonb) from public, anon, authenticated;

create or replace function public.set_transport_setting(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_key not in ('transport.required_documents', 'transport.token_tax_mandatory_for_contracted', 'transport.prorate') then
    raise exception 'SETTING_UNKNOWN' using errcode = '22023';
  end if;
  if p_key = 'transport.required_documents' and (jsonb_typeof(p_value) <> 'array'
     or exists (select 1 from jsonb_array_elements_text(p_value) x where x not in ('permit', 'fitness', 'token_tax', 'insurance'))) then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  end if;
  if p_key = 'transport.token_tax_mandatory_for_contracted' and jsonb_typeof(p_value) <> 'boolean' then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  end if;
  if p_key = 'transport.prorate' and (jsonb_typeof(p_value) <> 'string' or p_value #>> '{}' not in ('prorata', 'full_month')) then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  end if;
  insert into public.tenant_setting (tenant_id, key, value) values (app.auth_tenant_id(), p_key, p_value)
  on conflict (tenant_id, key) do update set value = excluded.value;
end;
$$;
revoke execute on function public.set_transport_setting(text, jsonb) from public, anon;
grant execute on function public.set_transport_setting(text, jsonb) to authenticated;

-- ── The block ───────────────────────────────────────────────────────────────
-- Returns the first reason the vehicle is not roadworthy on p_on, or null.
create or replace function app.fn_vehicle_block_reason(p_vehicle_id uuid, p_on date)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_v        public.transport_vehicle%rowtype;
  v_required jsonb;
  v_waive    boolean;
  t          public.transport_doc_type;
  v_label    text;
  v_exp      date;
  v_has      boolean;
begin
  select * into v_v from public.transport_vehicle where id = p_vehicle_id;
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not v_v.active then
    return 'vehicle is not active';
  end if;
  v_required := app.fn_transport_setting(v_v.tenant_id, 'transport.required_documents', '["fitness","token_tax","insurance"]'::jsonb);
  v_waive := not coalesce((app.fn_transport_setting(v_v.tenant_id, 'transport.token_tax_mandatory_for_contracted', 'true'::jsonb))::text::boolean, true);
  foreach t in array array['fitness', 'permit', 'insurance', 'token_tax']::public.transport_doc_type[] loop
    if t = 'token_tax' and v_v.ownership = 'contracted' and v_waive then
      continue;
    end if;
    select max(d.expires_on), true into v_exp, v_has
      from public.transport_vehicle_document d
     where d.vehicle_id = p_vehicle_id and d.doc_type = t and d.mandatory;
    v_label := case t when 'fitness' then 'fitness certificate' when 'permit' then 'route permit' when 'insurance' then 'insurance' else 'token tax' end;
    if v_exp is null then
      if v_required ? t::text then
        return v_label || ' is not on file';
      end if;
      continue;
    end if;
    if v_exp < p_on then
      return v_label || ' expired ' || (p_on - v_exp) || ' day' || case when p_on - v_exp = 1 then '' else 's' end || ' ago';
    end if;
  end loop;
  return null;
end;
$$;
revoke execute on function app.fn_vehicle_block_reason(uuid, date) from public, anon, authenticated;

-- Raises unless the vehicle is roadworthy on p_on or a Principal's override covers it.
create or replace function app.fn_vehicle_assert(p_vehicle_id uuid, p_on date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_reason text := app.fn_vehicle_block_reason(p_vehicle_id, p_on);
begin
  if v_reason is null then
    return;
  end if;
  if exists (select 1 from public.transport_vehicle_override o where o.vehicle_id = p_vehicle_id and p_on between o.valid_from and o.valid_to) then
    return;
  end if;
  raise exception 'VEHICLE_BLOCKED: %', v_reason;
end;
$$;
revoke execute on function app.fn_vehicle_assert(uuid, date) from public, anon, authenticated;

create or replace function public.assert_vehicle_roadworthy(p_vehicle_id uuid, p_on date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.transport_vehicle where id = p_vehicle_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_vehicle_assert(p_vehicle_id, p_on);
end;
$$;
revoke execute on function public.assert_vehicle_roadworthy(uuid, date) from public, anon;
grant execute on function public.assert_vehicle_roadworthy(uuid, date) to authenticated;

-- ── Writes ──────────────────────────────────────────────────────────────────
create or replace function public.save_transport_vehicle(
  p_campus_id uuid, p_reg_no text, p_seat_capacity int, p_make text default null, p_model text default null,
  p_fuel public.transport_fuel default 'diesel', p_ownership public.transport_ownership default 'owned',
  p_active boolean default true, p_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.fn_transport_assert_manager(p_campus_id);
  v_id     uuid;
  v_reg    text := upper(regexp_replace(btrim(p_reg_no), '\s+', ' ', 'g'));
begin
  if p_id is null then
    insert into public.transport_vehicle (tenant_id, campus_id, reg_no, make, model, seat_capacity, fuel, ownership, active)
    values (v_tenant, p_campus_id, v_reg, nullif(btrim(p_make), ''), nullif(btrim(p_model), ''), p_seat_capacity, p_fuel, p_ownership, p_active)
    returning id into v_id;
  else
    update public.transport_vehicle
       set reg_no = v_reg, make = nullif(btrim(p_make), ''), model = nullif(btrim(p_model), ''), seat_capacity = p_seat_capacity,
           fuel = p_fuel, ownership = p_ownership, active = p_active
     where id = p_id and tenant_id = v_tenant and campus_id = p_campus_id returning id into v_id;
    if v_id is null then
      raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'VEHICLE_REG_EXISTS' using errcode = '23505';
end;
$$;
revoke execute on function public.save_transport_vehicle(uuid, text, int, text, text, public.transport_fuel, public.transport_ownership, boolean, uuid) from public, anon;
grant execute on function public.save_transport_vehicle(uuid, text, int, text, text, public.transport_fuel, public.transport_ownership, boolean, uuid) to authenticated;

create or replace function public.add_vehicle_document(
  p_vehicle_id uuid, p_doc_type public.transport_doc_type, p_expires_on date, p_doc_no text default null,
  p_issued_on date default null, p_file_path text default null, p_mandatory boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_v  public.transport_vehicle%rowtype;
  v_id uuid;
begin
  select * into v_v from public.transport_vehicle where id = p_vehicle_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_transport_assert_manager(v_v.campus_id);
  if p_file_path is not null and (storage.foldername(p_file_path))[1] is distinct from v_v.tenant_id::text then
    raise exception 'FILE_PATH_INVALID' using errcode = '22023';
  end if;
  insert into public.transport_vehicle_document (tenant_id, campus_id, vehicle_id, doc_type, doc_no, issued_on, expires_on, file_path, mandatory, created_by)
  values (v_v.tenant_id, v_v.campus_id, p_vehicle_id, p_doc_type, nullif(btrim(p_doc_no), ''), p_issued_on, p_expires_on, p_file_path, p_mandatory, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_vehicle_document(uuid, public.transport_doc_type, date, text, date, text, boolean) from public, anon;
grant execute on function public.add_vehicle_document(uuid, public.transport_doc_type, date, text, date, text, boolean) to authenticated;

-- A named approver lifts the block for a span of dates.
create or replace function public.override_vehicle_block(p_vehicle_id uuid, p_from date, p_to date, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_v  public.transport_vehicle%rowtype;
  v_id uuid;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_v from public.transport_vehicle where id = p_vehicle_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'VEHICLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin') and not (v_v.campus_id = any (app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'REASON_MIN_LENGTH_10' using errcode = '23514';
  end if;
  if p_to < p_from then
    raise exception 'OVERRIDE_SPAN_INVALID' using errcode = '22023';
  end if;
  insert into public.transport_vehicle_override (tenant_id, campus_id, vehicle_id, valid_from, valid_to, reason, approved_by)
  values (v_v.tenant_id, v_v.campus_id, p_vehicle_id, p_from, p_to, btrim(p_reason), (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.override_vehicle_block(uuid, date, date, text) from public, anon;
grant execute on function public.override_vehicle_block(uuid, date, date, text) to authenticated;

-- ── Daily digest ────────────────────────────────────────────────────────────
-- One in-app message per Transport Manager and Principal of each campus listing
-- every document expiring within 30 days (or already expired). A document that
-- was listed within the last 7 days is not listed again. Returns the number of
-- documents listed.
create or replace function public.transport_document_expiry_digest(p_today date default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today  date := coalesce(p_today, app.fn_karachi_today());
  c        record;
  v_docs   record;
  v_lines  text;
  v_n      int;
  v_total  int := 0;
  v_ids    uuid[];
begin
  for c in
    select distinct d.tenant_id, d.campus_id
      from public.transport_vehicle_document d
      join public.transport_vehicle v on v.id = d.vehicle_id and v.active
     where d.mandatory and d.expires_on <= v_today + 30
  loop
    select string_agg(format('%s %s: %s (%s)', x.reg_no, x.doc_type, x.expires_on,
                             case when x.expires_on < v_today then 'expired ' || (v_today - x.expires_on) || ' days ago' else 'in ' || (x.expires_on - v_today) || ' days' end),
                      E'\n' order by x.expires_on, x.reg_no),
           count(*), array_agg(x.id)
      into v_lines, v_n, v_ids
      from (
        select distinct on (d.vehicle_id, d.doc_type) d.id, d.expires_on, d.doc_type, v.reg_no
          from public.transport_vehicle_document d
          join public.transport_vehicle v on v.id = d.vehicle_id and v.active
         where d.tenant_id = c.tenant_id and d.campus_id = c.campus_id and d.mandatory
         order by d.vehicle_id, d.doc_type, d.expires_on desc
      ) x
     where x.expires_on <= v_today + 30
       and not exists (select 1 from public.transport_document_alert a where a.document_id = x.id and a.last_sent_on > v_today - 7);
    continue when coalesce(v_n, 0) = 0;

    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    select c.tenant_id, au.user_id, 'transport_document_expiry',
           v_n || ' vehicle document' || case when v_n = 1 then '' else 's' end || ' expiring or expired',
           v_lines, '/transport/fleet'
      from public.app_user au
      join public.user_campus uc on uc.user_id = au.user_id and uc.campus_id = c.campus_id
     where au.tenant_id = c.tenant_id and au.app_role in ('transport_manager', 'principal') and au.status = 'active';

    insert into public.transport_document_alert (document_id, tenant_id, last_sent_on)
    select unnest(v_ids), c.tenant_id, v_today
    on conflict (document_id) do update set last_sent_on = excluded.last_sent_on;
    v_total := v_total + v_n;
  end loop;
  return v_total;
end;
$$;
revoke execute on function public.transport_document_expiry_digest(date) from public, anon, authenticated;
grant execute on function public.transport_document_expiry_digest(date) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('transport_document_expiry_digest', '30 1 * * *', 'select public.transport_document_expiry_digest();');
  end if;
exception
  when others then null;
end;
$$;

-- ── Storage: private bucket, path tenant_id/vehicle_id/file ─────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('transport-documents', 'transport-documents', false, 5242880, array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set file_size_limit = 5242880, allowed_mime_types = array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'];

create policy transport_documents_object_read on storage.objects for select to authenticated
  using (bucket_id = 'transport-documents'
         and (storage.foldername(name))[1] = app.auth_tenant_id()::text
         and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'));
create policy transport_documents_object_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'transport-documents'
              and (storage.foldername(name))[1] = app.auth_tenant_id()::text
              and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'transport_manager'));
