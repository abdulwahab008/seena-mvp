-- Front desk registers: visitors, phone calls, appointments, parcels, gate
-- passes, lost & found.
--
-- One table for all six. They share the same shape: someone (person_name,
-- phone), why (purpose), who they are for (host_name), a reference (ID card,
-- tracking or pass number), when it opened and when it was closed (signed out,
-- collected, returned, came back), and an optional follow-up date. A separate
-- table per register would mean six copies of the same columns, policies and
-- RPCs. The hostel keeps its own visitor log (hostel_visitor_log), which checks
-- the visitor against the resident's approved list.

create type public.front_desk_kind as enum ('visitor', 'call', 'appointment', 'parcel', 'gate_pass', 'lost_found');

create table public.front_desk_entry (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  campus_id    uuid not null references public.campus(id) on delete cascade,
  kind         public.front_desk_kind not null,
  person_name  text not null check (length(btrim(person_name)) between 1 and 200),
  phone        text check (phone is null or length(phone) <= 30),
  purpose      text check (purpose is null or length(purpose) <= 500),
  host_name    text check (host_name is null or length(host_name) <= 200),
  reference    text check (reference is null or length(reference) <= 100),
  details      text check (details is null or length(details) <= 2000),
  opened_at    timestamptz not null default now(),
  follow_up_on date,
  closed_at    timestamptz,
  close_note   text check (close_note is null or length(close_note) <= 500),
  created_by   uuid not null default auth.uid() references auth.users(id),
  closed_by    uuid references auth.users(id),
  created_at   timestamptz not null default now()
);

create index idx_front_desk_entry_scope on public.front_desk_entry (tenant_id, campus_id, kind, opened_at desc);
create index idx_front_desk_entry_open on public.front_desk_entry (campus_id, kind) where closed_at is null;

alter table public.front_desk_entry enable row level security;

create or replace function app.fn_front_desk_staff()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist');
$$;

create policy front_desk_entry_read on public.front_desk_entry
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.fn_front_desk_staff()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

select app.fn_block_portal_roles('public.front_desk_entry');

create trigger front_desk_entry_audit after insert or update or delete on public.front_desk_entry
  for each row execute function app.tg_audit_row();

create or replace function public.log_front_desk_entry(
  p_campus_id    uuid,
  p_kind         public.front_desk_kind,
  p_person_name  text,
  p_phone        text default null,
  p_purpose      text default null,
  p_host_name    text default null,
  p_reference    text default null,
  p_details      text default null,
  p_follow_up_on date default null
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
  if v_tenant_id is null or not app.fn_front_desk_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id and deleted_at is null) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;

  insert into public.front_desk_entry (tenant_id, campus_id, kind, person_name, phone, purpose, host_name, reference, details, follow_up_on)
  values (v_tenant_id, p_campus_id, p_kind, btrim(p_person_name), nullif(btrim(p_phone), ''), nullif(btrim(p_purpose), ''),
          nullif(btrim(p_host_name), ''), nullif(btrim(p_reference), ''), nullif(btrim(p_details), ''), p_follow_up_on)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.log_front_desk_entry(uuid, public.front_desk_kind, text, text, text, text, text, text, date) from public, anon;
grant execute on function public.log_front_desk_entry(uuid, public.front_desk_kind, text, text, text, text, text, text, date) to authenticated;

create or replace function public.close_front_desk_entry(p_entry_id uuid, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or not app.fn_front_desk_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.front_desk_entry e
     set closed_at = now(), closed_by = auth.uid(), close_note = nullif(btrim(p_note), '')
   where e.id = p_entry_id
     and e.tenant_id = app.auth_tenant_id()
     and e.closed_at is null
     and (app.auth_role() in ('super_admin', 'owner') or e.campus_id = any(app.auth_campus_ids()));
  if not found then
    raise exception 'ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.close_front_desk_entry(uuid, text) from public, anon;
grant execute on function public.close_front_desk_entry(uuid, text) to authenticated;
