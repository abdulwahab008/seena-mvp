-- Fix: FR-F15's timetable export printed a timetable with no clock times
-- and no campus logo, silently, for exactly the caller AC6 exists for.
--
-- timetable_export_payload() resolves the printed sheet's period columns
-- through resolve_bell_template(v_job.campus_id, ...) and its header logo
-- through resolve_branding(v_job.campus_id, 'logo'). Both grew a campus
-- guard in 20260731770000_security_definer_campus_scope_audit.sql: a
-- campus outside the CALLER's campus_ids claim resolves to NULL. The
-- payload's 'periods' array then comes back [] (nothing joins a NULL
-- bell_template_id) and 'logo_storage_path' comes back null, and the
-- renderer cheerfully produces a real, downloadable, correctly paginated
-- A4 sheet with an empty time column — the one outcome AC2 ("the sheets
-- on the noticeboard match the system exactly") cannot tolerate, and no
-- error anywhere to say so.
--
-- The cross-campus case is the visible one, but it is not the worst one.
-- FR-F15's own header (and FR-F12's before it) records that campus_ids is
-- populated from user_campus rows and that a teacher may simply have
-- none, leaving her claim '{}' — that is the ORDINARY shape for an
-- invited teacher. `not (p_campus_id = any('{}'))` is true for every
-- campus, so such a teacher gets a blank-timed, logo-less sheet for her
-- OWN campus. Refusing out-of-scope exports outright would therefore
-- refuse this FR's central use case, not protect it.
--
-- Decision: resolve UNSCOPED in the payload, and put the campus check
-- where FR-F15 already says scope belongs — at REQUEST time.
--
-- Why unscoped is right here specifically. This function's entire design
-- (its own header, third bullet) is that scope is resolved once at
-- request time and frozen onto the job row — scope_staff_id,
-- scope_section_ids, campus_id — and that the payload obeys the JOB,
-- never anything the caller passes or currently claims. That is
-- deliberate: it makes the scope un-spoofable, and it is the reason the
-- function is SECURITY DEFINER at all. Re-deriving authorization from
-- app.auth_campus_ids() deep inside it contradicts that design, and does
-- it in the worst available way — by blanking two fields rather than
-- refusing. The clock times and the logo are properties of the sheet the
-- job already authorized; they disclose nothing the job's own rows do
-- not. teacher_timetable() (FR-F12) made exactly this call in
-- 20260801010000, for exactly this reason.
--
-- Why the request-time gate is not optional. Resolving unscoped alone
-- would turn a blank foreign-campus sheet into a fully rendered one, and
-- request_timetable_export()'s teaching-role branch never campus-checked
-- the version at all: any teacher could name any version id in the
-- tenant. So AC6 ("a Teacher requests an export → only their own
-- per-teacher sheet is produced") is now enforced there, and the teacher
-- must be demonstrably tied to the version she is exporting. Her
-- campus_ids claim cannot be the whole test, for the '{}' reason above,
-- so it is: the version's campus is in her claim, OR she actually has a
-- period in that version. Otherwise EXPORT_SCOPE_FORBIDDEN (42501) —
-- which the export server action already surfaces as "You can only
-- export your own timetable sheet." A loud, specific refusal, never a
-- silently empty PDF.
--
-- The only request now refused that previously succeeded is one nothing
-- could authorize: a teaching role with an empty claim AND no period in
-- that version asking for a sheet of it. The admin branch
-- (Owner/Principal/Vice Principal/Exam Controller) is untouched, and the
-- class_teacher 'section' branch already refused when the teacher was
-- class teacher of no section of that version's campus.
--
-- app.resolve_branding_unscoped() gets the same containment
-- 20260801010000 gave app.resolve_bell_template_unscoped(), verbatim:
-- it lives in `app` (not exposed by PostgREST per config.toml), EXECUTE
-- is revoked from public, anon AND authenticated so only a
-- postgres-owned SECURITY DEFINER function that ran its own access check
-- can reach it, and tenant_id = app.auth_tenant_id() stays in the body —
-- a campus-scope escape hatch, never a tenant one.

create or replace function app.resolve_branding_unscoped(p_campus_id uuid, p_asset_type public.branding_asset_type)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_asset     public.branding_asset%rowtype;
begin
  select * into v_asset from public.branding_asset
   where tenant_id = v_tenant_id and campus_id = p_campus_id and asset_type = p_asset_type and is_current;
  if not found then
    select * into v_asset from public.branding_asset
     where tenant_id = v_tenant_id and campus_id is null and asset_type = p_asset_type and is_current;
  end if;
  if not found then
    return null;
  end if;
  return jsonb_build_object('asset_id', v_asset.id, 'storage_path', v_asset.storage_path);
end;
$$;

revoke execute on function app.resolve_branding_unscoped(uuid, public.branding_asset_type) from public, anon, authenticated;

-- Unchanged behaviour for every ordinary caller: an out-of-scope campus
-- still returns NULL, silently, exactly as the audit migration left it.
create or replace function public.resolve_branding(p_campus_id uuid, p_asset_type public.branding_asset_type)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    return null;
  end if;
  return app.resolve_branding_unscoped(p_campus_id, p_asset_type);
end;
$$;

-- AC6 lives here. An admin role (Owner/Principal/...) may request any
-- layout for a campus in its own scope, optionally narrowed to one teacher.
-- A teaching role may request ONLY the 'teacher' layout, ONLY for itself,
-- and only for a version it is actually tied to; a class teacher may
-- additionally take the 'section' layout, and it is silently narrowed to
-- the sections that person is actually class teacher of today —
-- requesting it is not an error, getting somebody else's section is
-- impossible.
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
      -- "Their OWN sheet" cannot be tested by campus_ids alone: a teacher
      -- with no user_campus row claims '{}' and would be locked out of her
      -- own campus. A period she actually teaches in this version is the
      -- other, equally direct way of being tied to it, and the one
      -- teacher_timetable() (FR-F12) already treats as authoritative for
      -- this same population.
      if not (v_version.campus_id = any(app.auth_campus_ids()))
         and not exists (
           select 1 from public.timetable_slot ts
            where ts.timetable_version_id = p_version_id and ts.staff_id = v_uid
         ) then
        raise exception 'EXPORT_SCOPE_FORBIDDEN' using errcode = '42501';
      end if;
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

-- Returns exactly what the per-section (FR-F11) and per-teacher (FR-F12)
-- screens already show, plus the header fields AC2 requires (school name,
-- logo, campus, session, timetable version number) and the Urdu subject
-- names AC4 requires. Slot rows are filtered by the JOB's own stored
-- scope, never by anything the caller passes — and now the clock times
-- and the logo are read the same way, from the job's campus, for the same
-- reason.
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
  v_template := app.resolve_bell_template_unscoped(v_job.campus_id, v_version.shift, v_bell_date);

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
    'logo_storage_path', (app.resolve_branding_unscoped(v_job.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
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
