-- FR-D06: document expiry reminders and compliance flag.
--
-- staff_document (FR-D02's deliberately minimal stand-in for the vault) gains
-- a document_type and an expires_on date. document_type_policy says which
-- types are mandatory (per tenant, optionally only for some contract types).
-- A nightly job, check_staff_document_expiry(), arms ONE reminder per
-- (document, threshold) in staff_document_reminder; the UNIQUE constraint is
-- the idempotency guarantee, so a job that dies at 01:15 and is re-run at
-- 03:00 (or run twice by hand) creates nothing twice, and the message queued
-- for module M delivery additionally carries an idempotency_key so even a
-- lost reminder row could not queue a second SMS.
--
-- Threshold rule: the tightest threshold already crossed. A document first
-- seen with 10 days left gets the 14-day reminder only, not 60/30/14 at once;
-- a retried or late job therefore never replays history to the whole staff.
--
-- Time zone: pg_cron schedules in UTC and Pakistan is UTC+5 with no DST, so
-- 01:15 PKT is '15 20 * * *' UTC; "today" is always app.fn_karachi_today().
--
-- Compliance is derived live (v_staff_compliance), so a renewal flips the
-- staff row back to 'compliant' at once, and the expiry-change trigger
-- clears the document's reminder rows so the new thresholds are armed on the
-- next run. A mandatory type with no dated document at all reads
-- 'incomplete' (distinct from a lapsed one, 'non_compliant').
--
-- staff_document.staff_id references app_user, so only staff who have a
-- login can hold documents; that is the existing FR-D02 model, not changed.

alter table public.staff_document add column if not exists document_type text;
alter table public.staff_document add column if not exists expires_on date;
create index if not exists idx_staff_document_expiry on public.staff_document (tenant_id, document_type, expires_on) where expires_on is not null;

create table public.document_type_policy (
  tenant_id                 uuid not null references public.tenant(id) on delete cascade,
  document_type             text not null check (document_type ~ '^[a-z][a-z0-9_]{1,39}$'),
  label                     text not null,
  is_mandatory              boolean not null default false,
  -- empty array = applies to every contract type
  applies_to_contract_types text[] not null default '{}',
  primary key (tenant_id, document_type)
);

create trigger document_type_policy_audit after insert or update or delete on public.document_type_policy
  for each row execute function app.tg_audit_row();

alter table public.document_type_policy enable row level security;
create policy document_type_policy_read on public.document_type_policy for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager'));

create or replace function app.tg_seed_document_type_policy()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.document_type_policy (tenant_id, document_type, label, is_mandatory) values
    (new.id, 'police_verification', 'Police verification certificate', true),
    (new.id, 'medical_certificate', 'Medical fitness certificate', true),
    (new.id, 'cnic_copy', 'CNIC copy', false),
    (new.id, 'degree', 'Degree / transcript', false)
  on conflict do nothing;
  return new;
end;
$$;

create trigger tenant_seed_document_type_policy after insert on public.tenant
  for each row execute function app.tg_seed_document_type_policy();

insert into public.document_type_policy (tenant_id, document_type, label, is_mandatory)
select t.id, v.document_type, v.label, v.is_mandatory
  from public.tenant t
 cross join (values
   ('police_verification', 'Police verification certificate', true),
   ('medical_certificate', 'Medical fitness certificate', true),
   ('cnic_copy', 'CNIC copy', false),
   ('degree', 'Degree / transcript', false)) as v(document_type, label, is_mandatory)
on conflict do nothing;

create table public.staff_document_reminder (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  document_id    uuid not null references public.staff_document(id) on delete cascade,
  threshold_days smallint not null check (threshold_days >= 0),
  generated_at   timestamptz not null default now(),
  message_id     uuid references public.message(id) on delete set null,
  constraint uq_document_reminder unique (document_id, threshold_days)
);
create index idx_document_reminder_document on public.staff_document_reminder (document_id);
create index idx_document_reminder_tenant on public.staff_document_reminder (tenant_id, generated_at desc);

alter table public.staff_document_reminder enable row level security;
create policy document_reminder_read on public.staff_document_reminder for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager'));

-- A new expiry date is a new obligation: forget the old thresholds so they re-arm.
create or replace function app.tg_staff_document_expiry_changed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.expires_on is distinct from old.expires_on then
    delete from public.staff_document_reminder where document_id = new.id;
  end if;
  return new;
end;
$$;

create trigger staff_document_expiry_changed after update of expires_on on public.staff_document
  for each row execute function app.tg_staff_document_expiry_changed();

-- ── HR write path ─────────────────────────────────────────────────────────

create or replace function public.add_staff_compliance_document(
  p_staff_id uuid, p_document_type text, p_expires_on date, p_label text default null, p_storage_path text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_label  text;
  v_id     uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_staff_id and tenant_id = v_tenant) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(nullif(btrim(p_label), ''), p.label) into v_label
    from public.document_type_policy p where p.tenant_id = v_tenant and p.document_type = p_document_type;
  if v_label is null then
    raise exception 'DOCUMENT_TYPE_UNKNOWN' using errcode = '22023';
  end if;
  insert into public.staff_document (tenant_id, staff_id, label, storage_path, uploaded_by, document_type, expires_on)
  values (v_tenant, p_staff_id, v_label, p_storage_path, (select auth.uid()), p_document_type, p_expires_on)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_staff_compliance_document(uuid, text, date, text, text) from public, anon;
grant execute on function public.add_staff_compliance_document(uuid, text, date, text, text) to authenticated;

-- Renew (or correct) a document's expiry. Same row, new date: compliance
-- recovers immediately and the reminder thresholds are re-armed by the trigger.
create or replace function public.set_staff_document_expiry(p_document_id uuid, p_expires_on date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.staff_document set expires_on = p_expires_on
   where id = p_document_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_staff_document_expiry(uuid, date) from public, anon;
grant execute on function public.set_staff_document_expiry(uuid, date) to authenticated;

create or replace function public.upsert_document_type_policy(
  p_document_type text, p_label text, p_is_mandatory boolean, p_contract_types text[] default '{}'
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  insert into public.document_type_policy (tenant_id, document_type, label, is_mandatory, applies_to_contract_types)
  values (app.auth_tenant_id(), p_document_type, p_label, p_is_mandatory, coalesce(p_contract_types, '{}'))
  on conflict (tenant_id, document_type) do update
    set label = excluded.label, is_mandatory = excluded.is_mandatory, applies_to_contract_types = excluded.applies_to_contract_types;
end;
$$;
revoke execute on function public.upsert_document_type_policy(text, text, boolean, text[]) from public, anon;
grant execute on function public.upsert_document_type_policy(text, text, boolean, text[]) to authenticated;

-- ── compliance view ───────────────────────────────────────────────────────

create or replace view public.v_staff_compliance with (security_invoker = true) as
select
  s.id as staff_id, s.tenant_id, s.campus_id, s.employee_code, s.full_name, s.user_id,
  coalesce(x.expired, '{}'::text[]) as expired_types,
  coalesce(x.missing, '{}'::text[]) as missing_types,
  case
    when cardinality(coalesce(x.expired, '{}'::text[])) > 0 then 'non_compliant'
    when cardinality(coalesce(x.missing, '{}'::text[])) > 0 then 'incomplete'
    else 'compliant'
  end as compliance_status
from public.staff s
left join lateral (
  select
    array_agg(p.document_type order by p.document_type) filter (where lat.latest_expiry is not null and lat.latest_expiry < app.fn_karachi_today()) as expired,
    array_agg(p.document_type order by p.document_type) filter (where lat.latest_expiry is null) as missing
  from public.document_type_policy p
  left join lateral (
    select max(d.expires_on) as latest_expiry
      from public.staff_document d
     where d.staff_id = s.user_id and d.document_type = p.document_type and d.expires_on is not null
  ) lat on true
  where p.tenant_id = s.tenant_id and p.is_mandatory
    and (cardinality(p.applies_to_contract_types) = 0 or s.contract_type = any (p.applies_to_contract_types))
) x on true
where s.employment_status <> 'exited'
  and (app.auth_role() in ('super_admin', 'owner', 'principal', 'hr_manager') or s.user_id = (select auth.uid()));

grant select on public.v_staff_compliance to authenticated;

-- ── the nightly job ───────────────────────────────────────────────────────

create or replace function public.check_staff_document_expiry(p_today date default null, p_tenant uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_today      date := coalesce(p_today, app.fn_karachi_today());
  v_thresholds smallint[] := array[0, 7, 14, 30, 60];
  r            record;
  v_threshold  smallint;
  v_reminder   uuid;
  v_message    uuid;
  v_created    integer := 0;
begin
  for r in
    select d.id as doc_id, d.tenant_id, d.document_type, d.expires_on, s.id as staff_id, s.user_id, s.campus_id, s.full_name, c.mobile
      from public.staff_document d
      join public.staff s on s.user_id = d.staff_id and s.tenant_id = d.tenant_id
      left join public.staff_private_contact c on c.staff_id = s.id
     where d.expires_on is not null
       and d.document_type is not null
       and s.employment_status <> 'exited'
       and (p_tenant is null or d.tenant_id = p_tenant)
       and d.expires_on - v_today <= 60
       -- only the newest document of a type matters: an older, replaced one never nags
       and d.expires_on = (select max(d2.expires_on) from public.staff_document d2 where d2.staff_id = d.staff_id and d2.document_type = d.document_type)
  loop
    select min(t) into v_threshold from unnest(v_thresholds) t where t >= greatest(r.expires_on - v_today, 0);

    insert into public.staff_document_reminder (tenant_id, document_id, threshold_days)
    values (r.tenant_id, r.doc_id, v_threshold)
    on conflict (document_id, threshold_days) do nothing
    returning id into v_reminder;

    if v_reminder is not null then
      v_created := v_created + 1;
      v_message := null;
      if r.mobile is not null and btrim(r.mobile) <> '' then
        insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, idempotency_key, metadata)
        values (
          r.tenant_id, r.campus_id, 'staff', r.user_id, r.mobile, 'sms',
          format('Reminder: your %s %s on %s. Please give the renewed document to HR.',
                 replace(r.document_type, '_', ' '),
                 case when r.expires_on < v_today then 'expired' else 'expires' end,
                 to_char(r.expires_on, 'DD Mon YYYY')),
          format('staffdoc:%s:%s', r.doc_id, v_threshold),
          jsonb_build_object('kind', 'staff_document_expiry', 'document_id', r.doc_id, 'threshold_days', v_threshold)
        )
        on conflict (tenant_id, idempotency_key) where idempotency_key is not null do nothing
        returning id into v_message;
        if v_message is not null then
          update public.staff_document_reminder set message_id = v_message where id = v_reminder;
        end if;
      end if;
    end if;
    v_reminder := null;
  end loop;
  return v_created;
end;
$$;
revoke execute on function public.check_staff_document_expiry(date, uuid) from public, anon, authenticated;

-- HR "run now" for their own school; the schedule below runs the global one.
create or replace function public.run_staff_document_expiry_check()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return public.check_staff_document_expiry(null, app.auth_tenant_id());
end;
$$;
revoke execute on function public.run_staff_document_expiry_check() from public, anon;
grant execute on function public.run_staff_document_expiry_check() to authenticated;

-- 01:15 PKT = 20:15 UTC (previous day).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('staff-doc-expiry', '15 20 * * *', 'select public.check_staff_document_expiry();');
  end if;
exception
  when others then null;
end;
$$;
