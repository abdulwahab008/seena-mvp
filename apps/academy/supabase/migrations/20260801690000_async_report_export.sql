-- FR-S08: asynchronous Excel export.
--
-- Requesting an export never blocks the browser: it records an audit row
-- (FR-S11, which enforces the PII reason), enqueues a job, and returns. A
-- long-running worker process claims jobs, pulls the dataset in pages, builds
-- the workbook and stores it in a private bucket; the requester is notified in
-- the app. A 45,000-row workbook would exhaust an edge function, so the
-- builder lives in the Next.js worker route, not here.
--
-- The worker is service_role, but the DATA is read as the requester: the
-- request-time claims are snapshotted on the job and re-established for each
-- page, and every dataset function checks role and campus scope itself, so a
-- job can never return more than its requester could have seen.

create table public.report_dataset (
  dataset_key   text primary key check (dataset_key ~ '^[a-z][a-z0-9_]+$'),
  display_name  text not null,
  columns       jsonb not null,
  allowed_roles text[] not null
);
alter table public.report_dataset enable row level security;
create policy report_dataset_read on public.report_dataset for select to authenticated
  using (app.auth_role() = any (allowed_roles));

insert into public.report_dataset (dataset_key, display_name, allowed_roles, columns) values
  ('students', 'Student list', array['owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer'],
   '[{"key":"gr_number","label":"GR number","type":"text"},{"key":"name_en","label":"Student name","type":"text"},{"key":"class_name","label":"Class","type":"text"},{"key":"section_name","label":"Section","type":"text"},{"key":"gender","label":"Gender","type":"text"},{"key":"dob","label":"Date of birth","type":"date"},{"key":"guardian_name","label":"Guardian","type":"text"},{"key":"guardian_cnic","label":"Guardian CNIC","type":"text"},{"key":"guardian_phone","label":"Guardian phone","type":"text"}]'),
  ('fee_collection', 'Fee collection', array['owner', 'super_admin', 'accountant', 'principal'],
   '[{"key":"value_date","label":"Date","type":"date"},{"key":"gr_number","label":"GR number","type":"text"},{"key":"student_name","label":"Student","type":"text"},{"key":"amount_paisa","label":"Amount (PKR)","type":"money"},{"key":"mode","label":"Mode","type":"text"},{"key":"reference_no","label":"Reference","type":"text"}]');

create table public.user_notification (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text,
  link       text,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index idx_user_notification_user on public.user_notification (user_id, created_at desc);
alter table public.user_notification enable row level security;
create policy user_notification_own on public.user_notification
  for select to authenticated using (tenant_id = app.auth_tenant_id() and user_id = (select auth.uid()));

create or replace function public.mark_notifications_read()
returns int
language sql
security definer
set search_path = ''
as $$
  with u as (update public.user_notification set read_at = now() where user_id = (select auth.uid()) and read_at is null returning 1)
  select count(*)::int from u;
$$;
revoke execute on function public.mark_notifications_read() from public, anon;
grant execute on function public.mark_notifications_read() to authenticated;

create table public.report_export_job (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  requested_by uuid not null references auth.users(id),
  dataset_key  text not null references public.report_dataset(dataset_key),
  params       jsonb not null default '{}'::jsonb,
  params_hash  text not null,
  format       text not null default 'xlsx' check (format in ('xlsx')),
  status       text not null default 'queued' check (status in ('queued', 'running', 'done', 'failed', 'expired')),
  claims       jsonb not null,
  audit_id     uuid references public.report_audit(id),
  row_count    int,
  storage_path text,
  attempts     int not null default 0,
  error        text,
  created_at   timestamptz not null default now(),
  started_at   timestamptz,
  finished_at  timestamptz,
  expires_at   timestamptz
);
create index idx_report_export_dedupe on public.report_export_job (requested_by, params_hash, format, created_at desc);
create index idx_report_export_queue on public.report_export_job (created_at) where status in ('queued', 'running');
create index idx_report_export_tenant on public.report_export_job (tenant_id, created_at desc);
alter table public.report_export_job enable row level security;
-- The claims snapshot never leaves the server: clients read through this view.
create policy report_export_job_requester_or_owner on public.report_export_job
  for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (requested_by = (select auth.uid()) or app.auth_role() in ('owner', 'super_admin')));

create view public.v_report_export_job with (security_invoker = true) as
select id, tenant_id, requested_by, dataset_key, params, format, status, row_count, error, created_at, finished_at, expires_at,
       (status = 'done' and storage_path is not null and expires_at > now()) as downloadable
  from public.report_export_job;

insert into storage.buckets (id, name, public, file_size_limit)
values ('report_exports', 'report_exports', false, 52428800)
on conflict (id) do update set public = false;

create policy report_export_requester_read on storage.objects
  for select to authenticated
  using (bucket_id = 'report_exports' and (storage.foldername(name))[2] = (select auth.uid())::text);

-- ── dataset readers: run as the requester by claims, scope enforced here ──

create or replace function app.fn_export_students(p_params jsonb, p_offset int, p_limit int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(r) from (
      select st.gr_number, st.name_en, cl.name_en as class_name, s.name as section_name, st.gender::text as gender, st.dob,
             g.name_en as guardian_name, g.cnic as guardian_cnic, g.phone_e164 as guardian_phone
        from public.enrolment e
        join public.student st on st.id = e.student_id
        join public.class_level cl on cl.id = e.class_level_id
        join public.class_section s on s.id = e.section_id
        left join lateral (
          select gg.name_en, gg.cnic, gg.phone_e164 from public.student_guardian sg join public.guardian gg on gg.id = sg.guardian_id
           where sg.student_id = st.id and sg.to_date is null order by sg.is_primary desc, sg.priority asc limit 1
        ) g on true
       where e.tenant_id = app.auth_tenant_id() and e.campus_id = any(app.auth_campus_ids())
         and e.status = 'active' and e.deleted_at is null
         and (p_params ->> 'class_level_id' is null or e.class_level_id = (p_params ->> 'class_level_id')::uuid)
       order by st.gr_number, e.id
       offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 10000)
    ) r
  ), '[]'::jsonb);
end;
$$;
revoke execute on function app.fn_export_students(jsonb, int, int) from public, anon, authenticated;

create or replace function app.fn_export_fee_collection(p_params jsonb, p_offset int, p_limit int)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(r) from (
      select p.value_date, st.gr_number, st.name_en as student_name, p.amount_paisa, p.mode::text as mode, p.reference_no
        from public.fee_payment p
        join public.enrolment e on e.id = p.enrolment_id
        join public.student st on st.id = e.student_id
       where p.tenant_id = app.auth_tenant_id() and p.campus_id = any(app.auth_campus_ids())
         and (p_params ->> 'from' is null or p.value_date >= (p_params ->> 'from')::date)
         and (p_params ->> 'to' is null or p.value_date <= (p_params ->> 'to')::date)
       order by p.value_date, p.id
       offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 10000)
    ) r
  ), '[]'::jsonb);
end;
$$;
revoke execute on function app.fn_export_fee_collection(jsonb, int, int) from public, anon, authenticated;

-- ── requesting ────────────────────────────────────────────────────────────

create or replace function public.request_report_export(p_dataset_key text, p_params jsonb, p_reason text default null, p_ip text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds       public.report_dataset%rowtype;
  v_uid      uuid := (select auth.uid());
  v_hash     text;
  v_existing uuid;
  v_audit    uuid;
  v_job      uuid;
begin
  if v_uid is null or app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  select * into v_ds from public.report_dataset where dataset_key = p_dataset_key;
  if not found or not (app.auth_role() = any (v_ds.allowed_roles)) then
    raise exception 'DATASET_NOT_AVAILABLE' using errcode = '42501';
  end if;

  v_hash := encode(extensions.digest(p_dataset_key || '|' || coalesce(p_params, '{}'::jsonb)::text, 'sha256'), 'hex');
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || v_hash, 0));

  -- The same user asking for the identical export within 60 s gets the same job.
  select id into v_existing from public.report_export_job
   where requested_by = v_uid and params_hash = v_hash and format = 'xlsx' and created_at > now() - interval '60 seconds'
   order by created_at desc limit 1;
  if v_existing is not null then
    return jsonb_build_object('job_id', v_existing, 'deduplicated', true);
  end if;

  v_audit := public.record_report_run(p_dataset_key, p_dataset_key, (select jsonb_agg(c ->> 'key') from jsonb_array_elements(v_ds.columns) c),
                                      coalesce(p_params, '{}'::jsonb), 0, p_reason, 'xlsx', p_ip);

  insert into public.report_export_job (tenant_id, requested_by, dataset_key, params, params_hash, claims, audit_id)
  values (app.auth_tenant_id(), v_uid, p_dataset_key, coalesce(p_params, '{}'::jsonb), v_hash,
          jsonb_build_object('sub', v_uid, 'tenant_id', app.auth_tenant_id(), 'app_role', app.auth_role(), 'campus_ids', to_jsonb(app.auth_campus_ids())),
          v_audit)
  returning id into v_job;

  return jsonb_build_object('job_id', v_job, 'deduplicated', false);
end;
$$;
revoke execute on function public.request_report_export(text, jsonb, text, text) from public, anon;
grant execute on function public.request_report_export(text, jsonb, text, text) to authenticated;

-- ── worker side (service_role only) ───────────────────────────────────────

create or replace function public.claim_export_job()
returns table (job_id uuid, tenant_id uuid, requested_by uuid, dataset_key text, params jsonb, columns jsonb, display_name text, requester_name text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  select j.id into v_id from public.report_export_job j
   where (j.status = 'queued' or (j.status = 'running' and j.started_at < now() - interval '10 minutes')) and j.attempts < 3
   order by j.created_at
   for update skip locked limit 1;
  if v_id is null then
    return;
  end if;
  update public.report_export_job set status = 'running', started_at = now(), attempts = attempts + 1 where id = v_id;

  return query
  select j.id, j.tenant_id, j.requested_by, j.dataset_key, j.params, d.columns, d.display_name,
         coalesce((select u.full_name from public.app_user u where u.user_id = j.requested_by), 'unknown')
    from public.report_export_job j join public.report_dataset d on d.dataset_key = j.dataset_key where j.id = v_id;
end;
$$;
revoke execute on function public.claim_export_job() from public, anon, authenticated;
grant execute on function public.claim_export_job() to service_role;

create or replace function public.export_job_page(p_job_id uuid, p_offset int, p_limit int)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
  v_prev text := current_setting('request.jwt.claims', true);
  v_rows jsonb;
begin
  select * into v_job from public.report_export_job where id = p_job_id and status = 'running';
  if not found then
    raise exception 'JOB_NOT_RUNNING' using errcode = '55000';
  end if;
  perform set_config('request.jwt.claims', v_job.claims::text, true);
  v_rows := case v_job.dataset_key
    when 'students' then app.fn_export_students(v_job.params, p_offset, p_limit)
    when 'fee_collection' then app.fn_export_fee_collection(v_job.params, p_offset, p_limit)
    else null end;
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  if v_rows is null then
    raise exception 'DATASET_NOT_IMPLEMENTED' using errcode = '0A000';
  end if;
  return v_rows;
exception when others then
  perform set_config('request.jwt.claims', coalesce(v_prev, ''), true);
  raise;
end;
$$;
revoke execute on function public.export_job_page(uuid, int, int) from public, anon, authenticated;
grant execute on function public.export_job_page(uuid, int, int) to service_role;

create or replace function public.complete_export_job(p_job_id uuid, p_row_count int, p_storage_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
begin
  update public.report_export_job
     set status = 'done', row_count = p_row_count, storage_path = p_storage_path, finished_at = now(), expires_at = now() + interval '30 days', error = null
   where id = p_job_id and status = 'running'
   returning * into v_job;
  if not found then
    return;
  end if;
  insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
  values (v_job.tenant_id, v_job.requested_by, 'report_export_ready', 'Your export is ready',
          p_row_count || ' rows — available for 30 days.', '/reports/exports');
end;
$$;
revoke execute on function public.complete_export_job(uuid, int, text) from public, anon, authenticated;
grant execute on function public.complete_export_job(uuid, int, text) to service_role;

create or replace function public.fail_export_job(p_job_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
begin
  update public.report_export_job
     set status = case when attempts >= 3 then 'failed' else 'queued' end, error = left(p_error, 500)
   where id = p_job_id and status = 'running'
   returning * into v_job;
  if found and v_job.status = 'failed' then
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    values (v_job.tenant_id, v_job.requested_by, 'report_export_failed', 'Your export could not be generated', 'Please request it again, or contact support if it keeps failing.', '/reports/exports');
  end if;
end;
$$;
revoke execute on function public.fail_export_job(uuid, text) from public, anon, authenticated;
grant execute on function public.fail_export_job(uuid, text) to service_role;

-- Retention: files expire after 30 days. The route deletes the object through
-- the storage API (deleting rows from storage.objects would orphan the blob),
-- then marks the job purged; a link used after that is an HTTP 410.
create or replace function public.export_jobs_to_purge(p_limit int default 200)
returns table (job_id uuid, storage_path text)
language sql
security definer
set search_path = ''
as $$
  select id, storage_path from public.report_export_job
   where status = 'done' and storage_path is not null and expires_at <= now()
   order by expires_at limit least(p_limit, 1000);
$$;
revoke execute on function public.export_jobs_to_purge(int) from public, anon, authenticated;
grant execute on function public.export_jobs_to_purge(int) to service_role;

create or replace function public.mark_export_purged(p_job_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.report_export_job set status = 'expired', storage_path = null where id = p_job_id and status = 'done';
$$;
revoke execute on function public.mark_export_purged(uuid) from public, anon, authenticated;
grant execute on function public.mark_export_purged(uuid) to service_role;
