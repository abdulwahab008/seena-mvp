-- FR-F15: timetable print and export.
--
-- "As a Principal, I want printable per-section, per-teacher and master-grid
-- timetables, so that the sheets on the noticeboard and in the staff room
-- match the system exactly."
--
-- What already existed: the whole timetable backbone. timetable_version
-- (FR-F04/F09/F10: DRAFT/PUBLISHED/SUPERSEDED, version_no, validity),
-- timetable_slot (one row per version/section/weekday/period, with subject,
-- staff, room, elective bucket), v_section_timetable (FR-F11),
-- teacher_timetable() (FR-F12), resolve_bell_template() (FR-F02, already
-- Ramadan-aware) and bell_period for real clock times, and
-- resolve_branding() (FR-A18) for the campus-then-tenant logo. This
-- migration adds no second copy of any of that — it adds the export job
-- and ONE payload function that reads exactly those tables.
--
-- Design notes:
--
--   * No Edge Function. This FR's own Supabase Objects spec names an Edge
--     Function `timetable-export-pdf`; this codebase has no
--     supabase/functions directory at all and no deployed Deno runtime, and
--     FR-T14 (audit trail export — the closest precedent, and the FR that
--     established the storage-bucket + async-job + signed-URL shape this
--     migration reuses wholesale) put the same work in a Next.js server
--     action instead. Repeating that is the honest choice: a Deno Edge
--     Function could not host the actual PDF renderer here either (see the
--     renderer note below), so an Edge Function would be an empty wrapper
--     around the same RPCs.
--
--   * ONE SECURITY DEFINER read: timetable_export_payload(job_id). Every
--     other read surface in module F is a security_invoker view over
--     RLS-scoped base tables (v_section_timetable's own header explains
--     why), and the export could have been assembled the same way from the
--     requester's own session. It deliberately is not, for two reasons that
--     only apply here:
--       - AC6 ("a Teacher requests an export → only their own per-teacher
--         sheet is produced") has to be enforced where the DATA comes from,
--         not in the UI. Reading the job's own stored scope columns inside
--         a definer function makes the scope un-spoofable: the server action
--         never passes a staff_id or a section list, it passes a job id.
--       - campus_ids is populated from user_campus rows
--         (custom_access_token_hook), and a teacher with no user_campus row
--         has campus_ids '{}' — timetable_slot_campus_scope would return
--         her zero rows for her OWN timetable. FR-F12 hit exactly this and
--         made teacher_timetable() SECURITY DEFINER for the same reason.
--
--   * Scope is resolved at REQUEST time and stored on the job
--     (scope_staff_id, scope_section_ids), never re-derived at render time
--     from the caller's current role. A class teacher who stops being a
--     class teacher tomorrow does not retroactively change what an
--     already-requested export contains, and the payload function has one
--     unambiguous source of truth for "what may this job see".
--
--   * scope_staff_id null means "every teacher, one page each" (AC2's own
--     48-teacher Principal export); non-null means one teacher (AC6).
--     scope_section_ids null means every section (AC1's 34-page export);
--     non-null narrows it to a class teacher's own sections. Two nullable
--     scope columns rather than a role check at render time — same
--     "resolved once, stored" reasoning as above.
--
--   * The renderer itself is NOT in the database and is not a new npm
--     dependency: apps/academy/lib/timetable-export/ builds print HTML
--     (@page size A4 portrait / A3 landscape) and renders it to real PDF
--     bytes through the headless Chromium that Playwright already ships for
--     the e2e suite. See lib/timetable-export/pdf.ts for the full
--     reasoning and the production caveat.
--
--   * purge_timetable_exports() is real and un-scheduled, the same
--     convention every other System-actor function this session has built
--     follows (purge_soft_deleted_records, purge_import_staging,
--     run_audit_chain_verification, dispatch_absentee_notifications): no
--     pg_cron exists locally, so the function is built and tested but never
--     scheduled.
--
--   * AC5 ("a signed URL issued at 10:00 returns 403 at 10:05 the NEXT
--     day") is implemented as a 24-hour createSignedUrl expiry and recorded
--     on the job as download_expires_at. Actually observing the 403 needs
--     24 hours of wall-clock time; it is not asserted anywhere in this
--     suite, and the expiry value is what is checked instead.

create type public.timetable_export_layout as enum ('section', 'teacher', 'master');
create type public.timetable_export_status as enum ('queued', 'running', 'completed', 'failed');

create table public.timetable_export_job (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  timetable_version_id uuid not null references public.timetable_version(id) on delete cascade,
  layout               public.timetable_export_layout not null,
  scope_staff_id       uuid references public.app_user(user_id),
  scope_section_ids    uuid[],
  status               public.timetable_export_status not null default 'queued',
  file_path            text,
  page_count           int,
  missing_glyph_count  int,
  font_family          text,
  download_url         text,
  download_expires_at  timestamptz,
  error                text,
  requested_by         uuid references public.app_user(user_id),
  requested_at         timestamptz not null default clock_timestamp(),
  completed_at         timestamptz
);

create index idx_export_job_version_layout on public.timetable_export_job (timetable_version_id, layout);
create index idx_export_job_status on public.timetable_export_job (status);
create index idx_export_job_requested_at on public.timetable_export_job (tenant_id, requested_at desc);

-- Who exported which timetable, when, and at what scope is itself an
-- auditable event — same reasoning (and same zero bespoke code) as
-- audit_export_job's own trigger in FR-T14.
create trigger timetable_export_job_audit after insert or update or delete on public.timetable_export_job
  for each row execute function app.tg_audit_row();

alter table public.timetable_export_job enable row level security;

create policy timetable_export_job_read on public.timetable_export_job
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or requested_by = (select auth.uid())
      or (
        app.auth_role() in ('principal', 'vice_principal', 'exam_controller')
        and campus_id = any(app.auth_campus_ids())
      )
    )
  );

-- Same hard-write-denial posture as audit_export_job: only the SECURITY
-- DEFINER functions below can write here.
revoke insert, update, delete on public.timetable_export_job from authenticated, anon;

-- ═══════════════════════════════════════════════════════════════════════
-- request / complete / fail
-- ═══════════════════════════════════════════════════════════════════════

-- AC6 lives here. An admin role (Owner/Principal/...) may request any
-- layout for a campus in its own scope, optionally narrowed to one teacher.
-- A teaching role may request ONLY the 'teacher' layout and ONLY for
-- itself; a class teacher may additionally take the 'section' layout, and
-- it is silently narrowed to the sections that person is actually class
-- teacher of today — requesting it is not an error, getting somebody
-- else's section is impossible.
create or replace function public.request_timetable_export(
  p_version_id uuid,
  p_layout public.timetable_export_layout,
  p_staff_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_uid         uuid := (select auth.uid());
  v_version     public.timetable_version%rowtype;
  v_scope_staff uuid;
  v_scope_secs  uuid[];
  v_job_id      uuid;
begin
  select * into v_version from public.timetable_version where id = p_version_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_role in ('super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller') then
    if v_role not in ('super_admin', 'owner') and not (v_version.campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    v_scope_staff := p_staff_id;
  elsif v_role in ('class_teacher', 'subject_teacher', 'head_of_department') then
    if p_staff_id is not null and p_staff_id <> v_uid then
      raise exception 'EXPORT_SCOPE_FORBIDDEN' using errcode = '42501';
    end if;
    if p_layout = 'teacher' then
      v_scope_staff := v_uid;
    elsif p_layout = 'section' and v_role = 'class_teacher' then
      select coalesce(array_agg(sct.section_id), '{}'::uuid[]) into v_scope_secs
        from public.section_class_teacher sct
        join public.class_section cs on cs.id = sct.section_id
       where sct.staff_id = v_uid
         and sct.validity @> current_date
         and cs.campus_id = v_version.campus_id
         and cs.session_id = v_version.session_id;
      if array_length(v_scope_secs, 1) is null then
        raise exception 'EXPORT_SCOPE_FORBIDDEN' using errcode = '42501';
      end if;
    else
      raise exception 'EXPORT_SCOPE_FORBIDDEN' using errcode = '42501';
    end if;
  else
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_scope_staff is not null and not exists (
    select 1 from public.app_user where user_id = v_scope_staff and tenant_id = v_tenant_id
  ) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.timetable_export_job (
    tenant_id, campus_id, timetable_version_id, layout, scope_staff_id, scope_section_ids, requested_by, status
  ) values (
    v_tenant_id, v_version.campus_id, p_version_id, p_layout, v_scope_staff, v_scope_secs, v_uid, 'running'
  )
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke execute on function public.request_timetable_export(uuid, public.timetable_export_layout, uuid) from public, anon;
grant execute on function public.request_timetable_export(uuid, public.timetable_export_layout, uuid) to authenticated;

create or replace function public.complete_timetable_export(
  p_job_id uuid,
  p_file_path text,
  p_page_count int,
  p_missing_glyph_count int,
  p_download_url text,
  -- Null whenever no Nastaliq face could be resolved on the render host —
  -- the sheet still prints, the job just says which font it actually used.
  p_font_family text default null,
  p_expires_hours int default 24
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.timetable_export_job%rowtype;
begin
  select * into v_job from public.timetable_export_job where id = p_job_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_job.requested_by is distinct from (select auth.uid()) and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.timetable_export_job
     set status = 'completed',
         file_path = p_file_path,
         page_count = p_page_count,
         missing_glyph_count = p_missing_glyph_count,
         font_family = p_font_family,
         download_url = p_download_url,
         download_expires_at = clock_timestamp() + make_interval(hours => p_expires_hours),
         completed_at = clock_timestamp()
   where id = p_job_id;
end;
$$;

revoke execute on function public.complete_timetable_export(uuid, text, int, int, text, text, int) from public, anon;
grant execute on function public.complete_timetable_export(uuid, text, int, int, text, text, int) to authenticated;

create or replace function public.fail_timetable_export(p_job_id uuid, p_error text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.timetable_export_job%rowtype;
begin
  select * into v_job from public.timetable_export_job where id = p_job_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_job.requested_by is distinct from (select auth.uid()) and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.timetable_export_job
     set status = 'failed', error = p_error, completed_at = clock_timestamp()
   where id = p_job_id;
end;
$$;

revoke execute on function public.fail_timetable_export(uuid, text) from public, anon;
grant execute on function public.fail_timetable_export(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The render payload — everything the printed sheet shows, in one read
-- ═══════════════════════════════════════════════════════════════════════

-- Returns exactly what the per-section (FR-F11) and per-teacher (FR-F12)
-- screens already show, plus the header fields AC2 requires (school name,
-- logo, campus, session, timetable version number) and the Urdu subject
-- names AC4 requires. Slot rows are filtered by the JOB's own stored
-- scope, never by anything the caller passes.
create or replace function public.timetable_export_payload(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_role       text := app.auth_role();
  v_job        public.timetable_export_job%rowtype;
  v_version    public.timetable_version%rowtype;
  v_bell_date  date;
  v_template   uuid;
  v_result     jsonb;
begin
  select * into v_job from public.timetable_export_job where id = p_job_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'JOB_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_job.requested_by is distinct from (select auth.uid())
     and not (
       v_role in ('super_admin', 'owner')
       or (v_role in ('principal', 'vice_principal', 'exam_controller') and v_job.campus_id = any(app.auth_campus_ids()))
     ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_version from public.timetable_version where id = v_job.timetable_version_id;

  -- Real clock times come from whichever bell template is in force for
  -- this version's own shift — on its effective date if it has one, else
  -- today for a draft being proofread before publication.
  v_bell_date := coalesce(v_version.effective_from, current_date);
  v_template := public.resolve_bell_template(v_job.campus_id, v_version.shift, v_bell_date);

  select jsonb_build_object(
    'job', jsonb_build_object(
      'id', v_job.id,
      'layout', v_job.layout,
      'scope_staff_id', v_job.scope_staff_id,
      'scope_section_ids', to_jsonb(v_job.scope_section_ids)
    ),
    'tenant', (
      select jsonb_build_object('name', t.name, 'name_ur', t.name_ur)
        from public.tenant t where t.id = v_tenant_id
    ),
    'campus', (
      select jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'name_ur', c.name_ur)
        from public.campus c where c.id = v_job.campus_id
    ),
    'session', (
      select jsonb_build_object('id', s.id, 'name', s.name)
        from public.academic_session s where s.id = v_version.session_id
    ),
    'version', jsonb_build_object(
      'id', v_version.id,
      'name', v_version.name,
      'version_no', v_version.version_no,
      'status', v_version.status,
      'shift', v_version.shift,
      'effective_from', v_version.effective_from,
      'effective_to', v_version.effective_to
    ),
    'logo_storage_path', (public.resolve_branding(v_job.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'periods', coalesce((
      select jsonb_agg(jsonb_build_object('period_no', bp.period_no, 'start_time', bp.start_time, 'end_time', bp.end_time)
                       order by bp.period_no)
        from public.bell_period bp
       where bp.bell_template_id = v_template and bp.kind = 'TEACHING' and bp.period_no is not null
    ), '[]'::jsonb),
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', cs.id,
               'name', cs.name,
               'medium', cs.medium,
               'class_level_name_en', cl.name_en,
               'class_level_name_ur', cl.name_ur,
               'class_level_ordinal', cl.ordinal
             ) order by cl.ordinal, cs.name)
        from public.class_section cs
        join public.class_level cl on cl.id = cs.class_level_id
       where cs.campus_id = v_job.campus_id
         and cs.session_id = v_version.session_id
         and cs.is_active
         and (v_job.scope_section_ids is null or cs.id = any(v_job.scope_section_ids))
    ), '[]'::jsonb),
    'slots', coalesce((
      select jsonb_agg(jsonb_build_object(
               'section_id', ts.section_id,
               'weekday', ts.weekday,
               'period_no', ts.period_no,
               'subject_code', subj.code,
               'subject_name_en', subj.name_en,
               'subject_name_ur', subj.name_ur,
               'staff_id', ts.staff_id,
               'teacher_name', au.full_name,
               'room_code', r.code,
               'elective_bucket', ts.elective_bucket
             ) order by ts.weekday, ts.period_no)
        from public.timetable_slot ts
        join public.subject subj on subj.id = ts.subject_id
        join public.class_section cs on cs.id = ts.section_id
        left join public.room r on r.id = ts.room_id
        left join public.app_user au on au.user_id = ts.staff_id
       where ts.timetable_version_id = v_job.timetable_version_id
         and (v_job.scope_section_ids is null or ts.section_id = any(v_job.scope_section_ids))
         and (v_job.scope_staff_id is null or ts.staff_id = v_job.scope_staff_id)
         and cs.is_active
    ), '[]'::jsonb),
    -- A scoped teacher is listed whether or not she has a single period in
    -- this version: her sheet is "one A4 page, entirely free" rather than a
    -- zero-page PDF that looks like the export silently failed.
    'teachers', case
      when v_job.scope_staff_id is not null then coalesce((
        select jsonb_agg(jsonb_build_object('id', au.user_id, 'name', au.full_name))
          from public.app_user au where au.user_id = v_job.scope_staff_id
      ), '[]'::jsonb)
      else coalesce((
        select jsonb_agg(distinct jsonb_build_object('id', au.user_id, 'name', au.full_name))
          from public.timetable_slot ts
          join public.app_user au on au.user_id = ts.staff_id
         where ts.timetable_version_id = v_job.timetable_version_id
           and (v_job.scope_section_ids is null or ts.section_id = any(v_job.scope_section_ids))
      ), '[]'::jsonb)
    end
  ) into v_result;

  return v_result;
end;
$$;

revoke execute on function public.timetable_export_payload(uuid) from public, anon;
grant execute on function public.timetable_export_payload(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Retention: exports are disposable, the timetable they render is not
-- ═══════════════════════════════════════════════════════════════════════

-- A printed timetable sheet is a snapshot of data that still lives in
-- timetable_slot — the PDF has no evidentiary value of its own (unlike an
-- audit export), so nothing is kept beyond a month. Real and tested,
-- deliberately un-scheduled: no pg_cron in this environment.
create or replace function public.purge_timetable_exports(p_older_than_days int default 30)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cutoff       timestamptz := now() - make_interval(days => p_older_than_days);
  v_paths        text[];
  v_objects      int;
  v_jobs         int;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select coalesce(array_agg(file_path), '{}'::text[]) into v_paths
    from public.timetable_export_job
   where requested_at < v_cutoff
     and file_path is not null
     and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id());

  delete from storage.objects
   where bucket_id = 'timetable-exports' and name = any(v_paths);
  get diagnostics v_objects = row_count;

  delete from public.timetable_export_job
   where requested_at < v_cutoff
     and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id());
  get diagnostics v_jobs = row_count;

  return jsonb_build_object('jobs_deleted', v_jobs, 'objects_deleted', v_objects);
end;
$$;

revoke execute on function public.purge_timetable_exports(int) from public, anon;
grant execute on function public.purge_timetable_exports(int) to authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════
-- Storage: private bucket, path is {campus_id}/{job_id}/<file>.pdf
-- ═══════════════════════════════════════════════════════════════════════

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('timetable-exports', 'timetable-exports', false, 104857600, array['application/pdf'])
on conflict (id) do nothing;

create policy timetable_export_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'timetable-exports'
    and exists (
      select 1 from public.timetable_export_job j
       where j.tenant_id = app.auth_tenant_id()
         and j.requested_by = (select auth.uid())
         and (storage.foldername(name))[1] = j.campus_id::text
         and (storage.foldername(name))[2] = j.id::text
    )
  );

-- AC: the path prefix must match a campus the caller is actually scoped
-- to. The second branch is what lets a Teacher fetch her OWN sheet even
-- though her campus_ids claim may be empty (no user_campus row) — the same
-- gap FR-F12 documented for teacher_timetable(); it grants nothing beyond
-- the file her own job produced.
create policy timetable_export_campus_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'timetable-exports'
    and (
      exists (
        select 1 from public.campus c
         where c.id::text = (storage.foldername(name))[1]
           and c.tenant_id = app.auth_tenant_id()
           and (app.auth_role() in ('super_admin', 'owner') or c.id = any(app.auth_campus_ids()))
      )
      or exists (
        select 1 from public.timetable_export_job j
         where j.tenant_id = app.auth_tenant_id()
           and j.requested_by = (select auth.uid())
           and (storage.foldername(name))[2] = j.id::text
      )
    )
  );
