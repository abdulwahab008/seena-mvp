-- FR-S09: branded PDF report rendering.
--
-- Reports reuse the asynchronous export queue (FR-S08): a PDF is a
-- report_export_job with format = 'pdf', claimed by the same worker, which renders
-- it with the house PDF seam (lib/pdf: headless Chromium + the Noto Nastaliq face
-- shared with certificates and report cards, so the font and shaping are solved
-- once). Print fidelity is a functional requirement here, not cosmetics: board and
-- education-department submissions are still paper in most districts.
--
-- Branding is NOT duplicated: logos and letterheads are the FR-A18 branding_asset
-- rows (campus-level, versioned, in the private `branding` bucket, written under the
-- existing branding_insert_owner storage policy). This FR adds what FR-A18 lacks —
-- the campus address in English and Urdu — and resolve_report_branding(), which
-- picks what a given campus prints: its own letterhead if it has one, otherwise the
-- logo (campus-level, else the tenant's), otherwise a text-only identity block.

create table public.campus_branding (
  campus_id  uuid primary key references public.campus(id) on delete cascade,
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  address_en text check (address_en is null or char_length(address_en) <= 300),
  address_ur text check (address_ur is null or char_length(address_ur) <= 300),
  updated_by uuid references public.app_user(user_id),
  updated_at timestamptz not null default clock_timestamp()
);
create index idx_campus_branding_tenant on public.campus_branding (tenant_id);
create trigger campus_branding_audit after insert or update or delete on public.campus_branding
  for each row execute function app.tg_audit_row();
alter table public.campus_branding enable row level security;
create policy campus_branding_read on public.campus_branding for select to authenticated
  using (tenant_id = app.auth_tenant_id() and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create or replace function public.set_campus_address(p_campus_id uuid, p_address_en text, p_address_ur text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus c where c.id = p_campus_id and c.tenant_id = app.auth_tenant_id()
                 and (app.auth_role() in ('owner', 'super_admin') or c.id = any (app.auth_campus_ids()))) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.campus_branding (campus_id, tenant_id, address_en, address_ur, updated_by, updated_at)
  values (p_campus_id, app.auth_tenant_id(), nullif(btrim(p_address_en), ''), nullif(btrim(p_address_ur), ''), (select auth.uid()), clock_timestamp())
  on conflict (campus_id) do update set address_en = excluded.address_en, address_ur = excluded.address_ur, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;
revoke execute on function public.set_campus_address(uuid, text, text) from public, anon;
grant execute on function public.set_campus_address(uuid, text, text) to authenticated;

-- What a campus prints. Paths only: the worker fetches the bytes from the private bucket.
create or replace function app.fn_report_branding(p_tenant_id uuid, p_campus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_letterhead text;
  v_logo       text;
  v_result     jsonb;
begin
  select ba.storage_path into v_letterhead from public.branding_asset ba
   where ba.tenant_id = p_tenant_id and ba.campus_id = p_campus_id and ba.asset_type = 'letterhead' and ba.is_current;
  select ba.storage_path into v_logo from public.branding_asset ba
   where ba.tenant_id = p_tenant_id and ba.asset_type = 'logo' and ba.is_current and (ba.campus_id = p_campus_id or ba.campus_id is null)
   order by (ba.campus_id is null) limit 1;
  select jsonb_build_object(
           'tenant_name', t.name, 'tenant_name_ur', t.name_ur, 'campus_name', c.name, 'campus_name_ur', c.name_ur,
           'address_en', coalesce(cb.address_en, c.address_line), 'address_ur', cb.address_ur,
           'letterhead_path', v_letterhead, 'logo_path', v_logo,
           'header_mode', case when v_letterhead is not null then 'letterhead' when v_logo is not null then 'logo' else 'none' end)
    into v_result
    from public.tenant t
    join public.campus c on c.tenant_id = t.id and c.id = p_campus_id
    left join public.campus_branding cb on cb.campus_id = c.id
   where t.id = p_tenant_id;
  return v_result;
end;
$$;
revoke execute on function app.fn_report_branding(uuid, uuid) from public, anon, authenticated;

create or replace function public.resolve_report_branding(p_campus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or not exists (select 1 from public.campus c where c.id = p_campus_id and c.tenant_id = app.auth_tenant_id()
       and (app.auth_role() in ('owner', 'super_admin') or c.id = any (app.auth_campus_ids()))) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_report_branding(app.auth_tenant_id(), p_campus_id);
end;
$$;
revoke execute on function public.resolve_report_branding(uuid) from public, anon;
grant execute on function public.resolve_report_branding(uuid) to authenticated;

-- ── the queue learns about PDFs ───────────────────────────────────────────

alter table public.report_export_job drop constraint if exists report_export_job_format_check;
alter table public.report_export_job add constraint report_export_job_format_check check (format in ('xlsx', 'pdf'));
alter table public.report_export_job
  add column if not exists orientation text check (orientation is null or orientation in ('portrait', 'landscape')),
  add column if not exists page_count int check (page_count is null or page_count >= 0);

create or replace view public.v_report_export_job with (security_invoker = true) as
select id, tenant_id, requested_by, dataset_key, params, format, status, row_count, error, created_at, finished_at, expires_at,
       (status = 'done' and storage_path is not null and expires_at > now()) as downloadable,
       orientation, page_count
  from public.report_export_job;

create or replace function public.request_report_pdf(p_dataset_key text, p_params jsonb, p_reason text default null, p_ip text default null)
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
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || v_hash || 'pdf', 0));

  select id into v_existing from public.report_export_job
   where requested_by = v_uid and params_hash = v_hash and format = 'pdf' and created_at > now() - interval '60 seconds'
   order by created_at desc limit 1;
  if v_existing is not null then
    return jsonb_build_object('job_id', v_existing, 'deduplicated', true);
  end if;

  v_audit := public.record_report_run(p_dataset_key, p_dataset_key, (select jsonb_agg(c ->> 'key') from jsonb_array_elements(v_ds.columns) c),
                                      coalesce(p_params, '{}'::jsonb), 0, p_reason, 'pdf', p_ip);

  insert into public.report_export_job (tenant_id, requested_by, dataset_key, params, params_hash, format, claims, audit_id)
  values (app.auth_tenant_id(), v_uid, p_dataset_key, coalesce(p_params, '{}'::jsonb), v_hash, 'pdf',
          jsonb_build_object('sub', v_uid, 'tenant_id', app.auth_tenant_id(), 'app_role', app.auth_role(), 'campus_ids', to_jsonb(app.auth_campus_ids())),
          v_audit)
  returning id into v_job;
  return jsonb_build_object('job_id', v_job, 'deduplicated', false);
end;
$$;
revoke execute on function public.request_report_pdf(text, jsonb, text, text) from public, anon;
grant execute on function public.request_report_pdf(text, jsonb, text, text) to authenticated;

-- The worker now needs to know the format and which campus's letterhead to print:
-- an explicit campus_id filter, else the requester's first campus.
drop function if exists public.claim_export_job();
create function public.claim_export_job()
returns table (job_id uuid, tenant_id uuid, requested_by uuid, dataset_key text, params jsonb, columns jsonb, display_name text, requester_name text, format text, campus_id uuid)
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
         coalesce((select u.full_name from public.app_user u where u.user_id = j.requested_by), 'unknown'),
         j.format,
         coalesce(nullif(j.params ->> 'campus_id', '')::uuid, nullif(j.claims -> 'campus_ids' ->> 0, '')::uuid)
    from public.report_export_job j join public.report_dataset d on d.dataset_key = j.dataset_key where j.id = v_id;
end;
$$;
revoke execute on function public.claim_export_job() from public, anon, authenticated;
grant execute on function public.claim_export_job() to service_role;

drop function if exists public.complete_export_job(uuid, int, text);
create function public.complete_export_job(p_job_id uuid, p_row_count int, p_storage_path text, p_page_count int default null, p_orientation text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.report_export_job%rowtype;
begin
  update public.report_export_job
     set status = 'done', row_count = p_row_count, storage_path = p_storage_path, finished_at = now(), expires_at = now() + interval '30 days', error = null,
         page_count = p_page_count, orientation = p_orientation
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
revoke execute on function public.complete_export_job(uuid, int, text, int, text) from public, anon, authenticated;
grant execute on function public.complete_export_job(uuid, int, text, int, text) to service_role;

-- Worker side: the branding of the job's campus (service role; tenant taken from the job itself).
create or replace function public.report_job_branding(p_job_id uuid, p_campus_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant uuid;
begin
  select tenant_id into v_tenant from public.report_export_job where id = p_job_id;
  if v_tenant is null then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_campus_id is null then
    select c.id into p_campus_id from public.campus c where c.tenant_id = v_tenant order by c.created_at limit 1;
  end if;
  return app.fn_report_branding(v_tenant, p_campus_id);
end;
$$;
revoke execute on function public.report_job_branding(uuid, uuid) from public, anon, authenticated;
grant execute on function public.report_job_branding(uuid, uuid) to service_role;
