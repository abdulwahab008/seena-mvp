-- FR-A19: tenant data export.
--
-- An Owner can take a complete copy of the school's records in an open format: one UTF-8
-- CSV per table (with a byte-order mark, because Excel on Windows is what school offices
-- run and it mis-renders Urdu without one) plus a manifest.json listing the row count of
-- every file. Nothing about the school's data is locked in.
--
-- Streaming, not buffering in the database: the archive is assembled by the long-running
-- worker (app/api/internal/exports/run), which pulls each table in pages through the
-- service-role-only tenant_export_page() — a 2,000-student attendance table alone would
-- overrun an edge function's memory and time. The worker reports the finished archive's
-- size and SHA-256 back, and completing a request writes exactly ONE row to
-- tenant_export_audit (requester, per-file row counts, checksum), append-only.
--
-- The archive is private and short-lived: the download link is valid for 72 hours from
-- completion; after that get_tenant_export_download() answers EXPORT_LINK_EXPIRED and a
-- new request must be made. A daily job marks lapsed archives expired and the worker
-- deletes the blobs (the bucket is private; deleting rows from storage.objects would
-- orphan the files). Bucket-level lifecycle rules are not configurable from SQL on this
-- platform, so this daily purge IS the 7-day retention backstop.
--
-- Who may export is the tenant.export permission (owner and super_admin), checked from
-- the caller's role bundle: a Principal gets 403 PERMISSION_DENIED.

insert into public.permission (code, module, label) values ('tenant.export', 'Foundation', 'Export all school data')
on conflict (code) do nothing;
insert into public.role_permission (role_id, permission_code)
select r.id, 'tenant.export' from public.role r where r.is_system and r.code in ('owner', 'super_admin')
on conflict do nothing;

create table public.tenant_export_source (
  table_key    text primary key check (table_key ~ '^[a-z_]+$'),
  file_name    text not null unique,
  source_table text not null,
  order_by     text not null
);
alter table public.tenant_export_source enable row level security;
create policy tenant_export_source_read on public.tenant_export_source for select to authenticated using (true);

insert into public.tenant_export_source (table_key, file_name, source_table, order_by) values
  ('students', 'students.csv', 'public.student', 'id'),
  ('guardians', 'guardians.csv', 'public.guardian', 'id'),
  ('student_guardians', 'student_guardians.csv', 'public.student_guardian', 'student_id, guardian_id'),
  ('enrolments', 'enrolments.csv', 'public.enrolment', 'id'),
  ('attendance', 'attendance.csv', 'public.attendance_day', 'id'),
  ('fee_challans', 'fee_challans.csv', 'public.fee_challan', 'id'),
  ('fee_ledger', 'fee_ledger.csv', 'public.fee_ledger', 'id'),
  ('payments', 'payments.csv', 'public.fee_payment', 'id'),
  ('marks', 'marks.csv', 'public.mark_entry', 'id'),
  ('staff', 'staff.csv', 'public.staff', 'id');

create table public.data_export_request (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  requested_by    uuid not null references auth.users(id),
  status          text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed', 'expired')),
  storage_path    text,
  bytes           bigint check (bytes is null or bytes >= 0),
  checksum_sha256 text check (checksum_sha256 is null or checksum_sha256 ~ '^[0-9a-f]{64}$'),
  row_counts      jsonb,
  attempts        int not null default 0,
  error           text,
  expires_at      timestamptz,
  created_at      timestamptz not null default clock_timestamp(),
  started_at      timestamptz,
  completed_at    timestamptz
);
create index idx_data_export_request_tenant on public.data_export_request (tenant_id, created_at desc);
create index idx_data_export_request_queue on public.data_export_request (created_at) where status in ('queued', 'running');
alter table public.data_export_request enable row level security;
-- export_owner_only
create policy export_owner_only on public.data_export_request for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.has_permission('tenant.export'));

create table public.tenant_export_audit (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  request_id      uuid not null unique references public.data_export_request(id),
  requested_by    uuid not null references auth.users(id),
  row_counts      jsonb not null,
  checksum_sha256 text not null check (checksum_sha256 ~ '^[0-9a-f]{64}$'),
  bytes           bigint not null,
  requested_at    timestamptz not null,
  completed_at    timestamptz not null default clock_timestamp()
);
create index idx_tenant_export_audit_tenant on public.tenant_export_audit (tenant_id, completed_at desc);
create or replace function app.fn_tenant_export_audit_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'audit_append_only' using errcode = '42501';
end;
$$;
create trigger trg_tenant_export_audit_append_only before update or delete on public.tenant_export_audit
  for each statement execute function app.fn_tenant_export_audit_append_only();
create trigger trg_tenant_export_audit_no_truncate before truncate on public.tenant_export_audit
  for each statement execute function app.fn_tenant_export_audit_append_only();
alter table public.tenant_export_audit enable row level security;
create policy tenant_export_audit_read on public.tenant_export_audit for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.has_permission('tenant.export'));

insert into storage.buckets (id, name, public, file_size_limit)
values ('tenant-exports', 'tenant-exports', false, 536870912)
on conflict (id) do update set public = false;

-- ── requesting ────────────────────────────────────────────────────────────

create or replace function public.request_tenant_export()
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_id  uuid;
begin
  if v_uid is null or app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if not app.has_permission('tenant.export') then
    raise exception 'PERMISSION_DENIED' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('tenant_export:' || app.auth_tenant_id()::text, 0));
  -- one export at a time per school: asking again while one is being prepared returns it
  select id into v_id from public.data_export_request where tenant_id = app.auth_tenant_id() and status in ('queued', 'running') order by created_at limit 1;
  if v_id is not null then
    return v_id;
  end if;
  insert into public.data_export_request (tenant_id, requested_by) values (app.auth_tenant_id(), v_uid) returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.request_tenant_export() from public, anon;
grant execute on function public.request_tenant_export() to authenticated;

-- The signed-link check. 72 hours after completion the link is dead; a new request is needed.
create or replace function public.get_tenant_export_download(p_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_req public.data_export_request%rowtype;
begin
  if app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if not app.has_permission('tenant.export') then
    raise exception 'PERMISSION_DENIED' using errcode = '42501';
  end if;
  select * into v_req from public.data_export_request where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'EXPORT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_req.status = 'expired' or (v_req.status = 'done' and v_req.expires_at <= now()) then
    raise exception 'EXPORT_LINK_EXPIRED' using errcode = 'P0001', hint = 'Request a new export';
  end if;
  if v_req.status <> 'done' or v_req.storage_path is null then
    raise exception 'EXPORT_NOT_READY' using errcode = '55000';
  end if;
  return v_req.storage_path;
end;
$$;
revoke execute on function public.get_tenant_export_download(uuid) from public, anon;
grant execute on function public.get_tenant_export_download(uuid) to authenticated;

-- ── worker side (service_role only) ───────────────────────────────────────

create or replace function public.claim_tenant_export()
returns table (request_id uuid, tenant_id uuid, requested_by uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select r.id into v_id from public.data_export_request r
   where (r.status = 'queued' or (r.status = 'running' and r.started_at < now() - interval '30 minutes')) and r.attempts < 3
   order by r.created_at
   for update skip locked limit 1;
  if v_id is null then
    return;
  end if;
  update public.data_export_request set status = 'running', started_at = now(), attempts = attempts + 1 where id = v_id;
  return query select r.id, r.tenant_id, r.requested_by from public.data_export_request r where r.id = v_id;
end;
$$;
revoke execute on function public.claim_tenant_export() from public, anon, authenticated;
grant execute on function public.claim_tenant_export() to service_role;

create or replace function public.tenant_export_tables()
returns table (table_key text, file_name text, columns text[])
language sql
stable
security definer
set search_path = ''
as $$
  select s.table_key, s.file_name,
         (select array_agg(a.attname::text order by a.attnum) from pg_catalog.pg_attribute a where a.attrelid = s.source_table::regclass and a.attnum > 0 and not a.attisdropped)
    from public.tenant_export_source s order by s.table_key;
$$;
revoke execute on function public.tenant_export_tables() from public, anon, authenticated;
grant execute on function public.tenant_export_tables() to service_role;

-- One page of one table for the running request's own tenant — the tenant comes from the request, never from the caller.
create or replace function public.tenant_export_page(p_request_id uuid, p_table_key text, p_offset int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
  v_src    public.tenant_export_source%rowtype;
  v_rows   jsonb;
begin
  select tenant_id into v_tenant from public.data_export_request where id = p_request_id and status = 'running';
  if v_tenant is null then
    raise exception 'EXPORT_NOT_RUNNING' using errcode = '55000';
  end if;
  select * into v_src from public.tenant_export_source where table_key = p_table_key;
  if not found then
    raise exception 'EXPORT_TABLE_UNKNOWN' using errcode = '22023';
  end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), %L::jsonb) from (select * from %s where tenant_id = $1 order by %s offset $2 limit $3) t',
                 '[]', v_src.source_table, v_src.order_by)
    into v_rows using v_tenant, greatest(p_offset, 0), least(greatest(p_limit, 1), 20000);
  return v_rows;
end;
$$;
revoke execute on function public.tenant_export_page(uuid, text, int, int) from public, anon, authenticated;
grant execute on function public.tenant_export_page(uuid, text, int, int) to service_role;

create or replace function public.complete_tenant_export(p_request_id uuid, p_storage_path text, p_bytes bigint, p_checksum text, p_row_counts jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r     public.data_export_request%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  update public.data_export_request
     set status = 'done', storage_path = p_storage_path, bytes = p_bytes, checksum_sha256 = p_checksum, row_counts = p_row_counts,
         completed_at = v_now, expires_at = v_now + interval '72 hours', error = null
   where id = p_request_id and status = 'running'
   returning * into r;
  if not found then
    return;
  end if;
  -- exactly one audit row per export: who asked, what was in it, and the archive's fingerprint
  insert into public.tenant_export_audit (tenant_id, request_id, requested_by, row_counts, checksum_sha256, bytes, requested_at, completed_at)
  values (r.tenant_id, r.id, r.requested_by, p_row_counts, p_checksum, p_bytes, r.created_at, r.completed_at);
  insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
  values (r.tenant_id, r.requested_by, 'tenant_export_ready', 'Your school data export is ready', 'The download link works for 72 hours.', '/settings/data-export');
end;
$$;
revoke execute on function public.complete_tenant_export(uuid, text, bigint, text, jsonb) from public, anon, authenticated;
grant execute on function public.complete_tenant_export(uuid, text, bigint, text, jsonb) to service_role;

create or replace function public.fail_tenant_export(p_request_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.data_export_request%rowtype;
begin
  update public.data_export_request set status = case when attempts >= 3 then 'failed' else 'queued' end, error = left(p_error, 500)
   where id = p_request_id and status = 'running' returning * into r;
  if found and r.status = 'failed' then
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    values (r.tenant_id, r.requested_by, 'tenant_export_failed', 'Your school data export could not be built', 'Please request it again, or contact support if it keeps failing.', '/settings/data-export');
  end if;
end;
$$;
revoke execute on function public.fail_tenant_export(uuid, text) from public, anon, authenticated;
grant execute on function public.fail_tenant_export(uuid, text) to service_role;

-- ── retention: purge_expired_exports, daily 03:00 ─────────────────────────

create or replace function public.expire_tenant_exports()
returns int
language sql
security definer
set search_path = ''
as $$
  with u as (update public.data_export_request set status = 'expired' where status = 'done' and expires_at <= now() returning 1)
  select count(*)::int from u;
$$;
revoke execute on function public.expire_tenant_exports() from public, anon, authenticated;
grant execute on function public.expire_tenant_exports() to service_role;

create or replace function public.tenant_exports_to_purge(p_limit int default 200)
returns table (request_id uuid, storage_path text)
language sql
security definer
set search_path = ''
as $$
  select id, storage_path from public.data_export_request where status = 'expired' and storage_path is not null order by expires_at limit least(p_limit, 1000);
$$;
revoke execute on function public.tenant_exports_to_purge(int) from public, anon, authenticated;
grant execute on function public.tenant_exports_to_purge(int) to service_role;

create or replace function public.mark_tenant_export_purged(p_request_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.data_export_request set storage_path = null where id = p_request_id and status = 'expired';
$$;
revoke execute on function public.mark_tenant_export_purged(uuid) from public, anon, authenticated;
grant execute on function public.mark_tenant_export_purged(uuid) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- 03:00 Asia/Karachi = 22:00 UTC
    perform cron.schedule('purge_expired_exports', '0 22 * * *', 'select public.expire_tenant_exports();');
  end if;
exception
  when others then null;
end;
$$;
