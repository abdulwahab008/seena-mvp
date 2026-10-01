-- FR-I04: datesheet publication and versioning.
--
-- Datesheets shift constantly and are circulated as screenshots, so publication
-- never mutates anything a parent may have a picture of. Publishing copies the
-- slots into an immutable snapshot under a new version number; the working
-- datesheet becomes read-only. To revise, the controller reopens it, edits and
-- publishes again: that is version 2, version 1 stays retrievable, and every
-- snapshot row says whether it is new, moved or unchanged against the version
-- before it so the parent view can highlight what changed.
--
--   * a draft datesheet is invisible to parents and students (they get no policy
--     on datesheet or datesheet_slot at all);
--   * datesheet_version and datesheet_slot_snapshot are append-only: updates and
--     deletes are refused by triggers (only a cascade from deleting the whole
--     tenant gets through), and a version row may only move published ->
--     superseded or record its rendered PDF;
--   * the PDF is rendered by the app (Chromium, Nastaliq embedded) into the
--     private "datesheets" bucket and handed out as 7-day signed URLs - the
--     bucket has no read policy, so nobody reads it directly.

create table public.datesheet_version (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  campus_id      uuid not null references public.campus(id) on delete cascade,
  datesheet_id   uuid not null references public.datesheet(id) on delete cascade,
  version_no     int not null check (version_no >= 1),
  status         text not null default 'published' check (status in ('published', 'superseded')),
  note           text check (note is null or char_length(note) <= 500),
  slot_count     int not null,
  published_by   uuid references auth.users(id),
  published_at   timestamptz not null default now(),
  pdf_path       text,
  pdf_generated_at timestamptz
);
create unique index uq_datesheet_version on public.datesheet_version (datesheet_id, version_no);
create index idx_datesheet_version_tenant on public.datesheet_version (tenant_id);
create index idx_datesheet_version_campus on public.datesheet_version (campus_id);

create table public.datesheet_slot_snapshot (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  version_id       uuid not null references public.datesheet_version(id) on delete cascade,
  datesheet_id     uuid not null references public.datesheet(id) on delete cascade,
  source_slot_id   uuid,
  exam_subject_id  uuid not null references public.exam_subject(id) on delete cascade,
  class_level_id   uuid not null references public.class_level(id),
  class_name       text not null,
  subject_name_en  text not null,
  subject_name_ur  text,
  start_at         timestamptz not null,
  end_at           timestamptz not null,
  hall_name        text,
  change_kind      text not null default 'new' check (change_kind in ('new', 'moved', 'unchanged')),
  previous_start_at timestamptz,
  previous_end_at   timestamptz
);
create index idx_slot_snapshot_version on public.datesheet_slot_snapshot (version_id, start_at);
create index idx_slot_snapshot_class on public.datesheet_slot_snapshot (class_level_id);
create index idx_slot_snapshot_subject on public.datesheet_slot_snapshot (exam_subject_id);
create index idx_slot_snapshot_tenant on public.datesheet_slot_snapshot (tenant_id);
create index idx_slot_snapshot_datesheet on public.datesheet_slot_snapshot (datesheet_id);

create trigger datesheet_version_audit after insert or update or delete on public.datesheet_version
  for each row execute function app.tg_audit_row();

-- ── immutability ──────────────────────────────────────────────────────────
-- pg_trigger_depth() = 1 is a statement that targets this table directly; a
-- cascade from deleting the tenant or the datesheet runs one level deeper.
create or replace function app.tg_datesheet_snapshot_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'a published datesheet snapshot is immutable' using errcode = '42501',
    hint = 'Reopen the datesheet and publish a new version instead.';
end;
$$;
create trigger trg_slot_snapshot_immutable before update or delete on public.datesheet_slot_snapshot
  for each row execute function app.tg_datesheet_snapshot_immutable();
create trigger trg_slot_snapshot_no_truncate before truncate on public.datesheet_slot_snapshot
  for each statement execute function app.tg_table_no_truncate();

create or replace function app.tg_datesheet_version_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if pg_trigger_depth() > 1 then
      return old;
    end if;
    raise exception 'a published datesheet version cannot be deleted' using errcode = '42501';
  end if;
  if (new.id, new.tenant_id, new.campus_id, new.datesheet_id, new.version_no, new.note, new.slot_count, new.published_by, new.published_at)
     is distinct from
     (old.id, old.tenant_id, old.campus_id, old.datesheet_id, old.version_no, old.note, old.slot_count, old.published_by, old.published_at)
     or (old.status = 'superseded' and new.status <> 'superseded') then
    raise exception 'a published datesheet version is immutable' using errcode = '42501';
  end if;
  return new;
end;
$$;
create trigger trg_datesheet_version_guard before update or delete on public.datesheet_version
  for each row execute function app.tg_datesheet_version_guard();
create trigger trg_datesheet_version_no_truncate before truncate on public.datesheet_version
  for each statement execute function app.tg_table_no_truncate();

-- ── the working copy is read-only while published ─────────────────────────
create or replace function app.tg_datesheet_slot_readonly()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  select status into v_status from public.datesheet where id = coalesce(new.datesheet_id, old.datesheet_id);
  if v_status = 'published' then
    raise exception 'DATESHEET_READONLY' using errcode = '22023';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
create trigger trg_datesheet_slot_readonly before insert or update or delete on public.datesheet_slot
  for each row execute function app.tg_datesheet_slot_readonly();

-- ── visibility ────────────────────────────────────────────────────────────
-- The class levels of the caller's own children (guardian) or of the caller
-- themself (student portal account).
create or replace function app.fn_my_class_level_ids()
returns uuid[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(distinct e.class_level_id), '{}'::uuid[])
    from public.enrolment e
   where e.status = 'active' and e.deleted_at is null
     and (e.student_id = public.my_student_id() or e.student_id = any (app.auth_guardian_student_ids()));
$$;
revoke execute on function app.fn_my_class_level_ids() from public, anon;
grant execute on function app.fn_my_class_level_ids() to authenticated;

alter table public.datesheet_version enable row level security;
alter table public.datesheet_slot_snapshot enable row level security;

create policy datesheet_version_campus_scope on public.datesheet_version for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
-- Parents and students: published (and superseded) versions of a datesheet that
-- schedules a paper of their own class. A draft has no version row at all.
create policy datesheet_version_published_read on public.datesheet_version for select to authenticated
  using (tenant_id = app.auth_tenant_id() and status in ('published', 'superseded')
         and exists (select 1 from public.datesheet_slot_snapshot s where s.version_id = datesheet_version.id and s.class_level_id = any (app.fn_my_class_level_ids())));
create policy datesheet_slot_snapshot_campus_scope on public.datesheet_slot_snapshot for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy datesheet_parent_scope on public.datesheet_slot_snapshot for select to authenticated
  using (tenant_id = app.auth_tenant_id() and class_level_id = any (app.fn_my_class_level_ids()));

-- ═══════════════════════════════════════════════════════════════════════
-- Publish, reopen
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.publish_datesheet(p_datesheet_id uuid, p_note text default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds      public.datesheet%rowtype;
  v_version int;
  v_vid     uuid;
  v_prev    uuid;
  v_gr      text[];
  v_count   int;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ds.campus_id);
  if v_ds.status <> 'draft' then
    raise exception 'DATESHEET_NOT_DRAFT' using errcode = '22023';
  end if;
  if not exists (select 1 from public.datesheet_slot where datesheet_id = p_datesheet_id) then
    raise exception 'DATESHEET_EMPTY' using errcode = '22023';
  end if;
  if char_length(coalesce(p_note, '')) > 500 then
    raise exception 'NOTE_TOO_LONG' using errcode = '22023';
  end if;

  select count(distinct g)::int, coalesce(array_agg(distinct g order by g), '{}'::text[])
    into v_count, v_gr
    from public.fn_detect_datesheet_clash(p_datesheet_id) c, unnest(c.affected_gr_numbers) g;
  if v_count > 0 then
    raise exception 'DATESHEET_HAS_CLASHES' using errcode = '23P01', detail = format('%s candidates are in overlapping papers: %s', v_count, array_to_string(v_gr, ', '));
  end if;

  v_version := v_ds.current_version + 1;
  select id into v_prev from public.datesheet_version where datesheet_id = p_datesheet_id and version_no = v_ds.current_version;

  insert into public.datesheet_version (tenant_id, campus_id, datesheet_id, version_no, note, slot_count, published_by)
  values (v_ds.tenant_id, v_ds.campus_id, p_datesheet_id, v_version, nullif(btrim(p_note), ''),
          (select count(*) from public.datesheet_slot where datesheet_id = p_datesheet_id), (select auth.uid()))
  returning id into v_vid;

  insert into public.datesheet_slot_snapshot (
    tenant_id, campus_id, version_id, datesheet_id, source_slot_id, exam_subject_id, class_level_id, class_name,
    subject_name_en, subject_name_ur, start_at, end_at, hall_name, change_kind, previous_start_at, previous_end_at)
  select s.tenant_id, s.campus_id, v_vid, s.datesheet_id, s.id, s.exam_subject_id, cs.class_level_id, cl.name_en,
         sub.name_en, sub.name_ur, s.start_at, s.end_at, h.name,
         case when p.id is null then 'new'
              when p.start_at = s.start_at and p.end_at = s.end_at and p.hall_name is not distinct from h.name then 'unchanged'
              else 'moved' end,
         case when p.id is not null and (p.start_at <> s.start_at or p.end_at <> s.end_at) then p.start_at end,
         case when p.id is not null and (p.start_at <> s.start_at or p.end_at <> s.end_at) then p.end_at end
    from public.datesheet_slot s
    join public.exam_subject es on es.id = s.exam_subject_id
    join public.class_subject cs on cs.id = es.class_subject_id
    join public.class_level cl on cl.id = cs.class_level_id
    join public.subject sub on sub.id = cs.subject_id
    left join public.exam_hall h on h.id = s.hall_id
    left join public.datesheet_slot_snapshot p on p.version_id = v_prev and p.exam_subject_id = s.exam_subject_id
   where s.datesheet_id = p_datesheet_id;

  if v_prev is not null then
    update public.datesheet_version set status = 'superseded' where id = v_prev;
  end if;
  update public.datesheet set status = 'published', current_version = v_version where id = p_datesheet_id;
  return v_version;
end;
$$;
revoke execute on function public.publish_datesheet(uuid, text) from public, anon;
grant execute on function public.publish_datesheet(uuid, text) to authenticated;

create or replace function public.reopen_datesheet(p_datesheet_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ds public.datesheet%rowtype;
begin
  select * into v_ds from public.datesheet where id = p_datesheet_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'DATESHEET_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ds.campus_id);
  if v_ds.status <> 'published' then
    raise exception 'DATESHEET_NOT_PUBLISHED' using errcode = '22023';
  end if;
  update public.datesheet set status = 'draft' where id = p_datesheet_id;
end;
$$;
revoke execute on function public.reopen_datesheet(uuid) from public, anon;
grant execute on function public.reopen_datesheet(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Parent / student view
-- ═══════════════════════════════════════════════════════════════════════

-- The latest published version of one datesheet for one pupil: only the papers
-- they actually sit (electives resolved through enrolment), each flagged with
-- whether it changed against the version before. {"has_datesheet": false} when
-- nothing has been published, which includes "still a draft".
create or replace function public.fn_portal_datesheet(p_enrolment_id uuid, p_datesheet_id uuid default null, p_version_no int default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_enr  public.enrolment%rowtype;
  v_ds   uuid;
  v_title text;
  v_ver  public.datesheet_version%rowtype;
  v_list jsonb;
  v_dlist jsonb;
  v_rows jsonb;
begin
  if not app.fn_is_own_enrolment(p_enrolment_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_enr from public.enrolment where id = p_enrolment_id and deleted_at is null;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title) order by d.created_at desc), '[]'::jsonb)
    into v_dlist
    from public.datesheet d
   where d.tenant_id = v_enr.tenant_id and d.campus_id = v_enr.campus_id and d.current_version >= 1
     and exists (select 1 from public.datesheet_version v join public.datesheet_slot_snapshot s on s.version_id = v.id
                  where v.datesheet_id = d.id and s.class_level_id = v_enr.class_level_id);
  if jsonb_array_length(v_dlist) = 0 then
    return jsonb_build_object('has_datesheet', false);
  end if;
  v_ds := coalesce(p_datesheet_id, (v_dlist -> 0 ->> 'id')::uuid);
  select title into v_title from public.datesheet where id = v_ds and tenant_id = v_enr.tenant_id and campus_id = v_enr.campus_id and current_version >= 1;
  if v_title is null then
    return jsonb_build_object('has_datesheet', false);
  end if;

  select * into v_ver from public.datesheet_version
   where datesheet_id = v_ds and version_no = coalesce(p_version_no, (select max(version_no) from public.datesheet_version where datesheet_id = v_ds));
  if not found then
    return jsonb_build_object('has_datesheet', false);
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'version_no', version_no, 'status', status, 'published_at', published_at) order by version_no desc), '[]'::jsonb)
    into v_list from public.datesheet_version where datesheet_id = v_ds;

  select coalesce(jsonb_agg(jsonb_build_object(
           'subject_name_en', s.subject_name_en, 'subject_name_ur', s.subject_name_ur, 'start_at', s.start_at, 'end_at', s.end_at,
           'hall_name', s.hall_name, 'change_kind', s.change_kind, 'previous_start_at', s.previous_start_at,
           'changed', (v_ver.version_no > 1 and s.change_kind <> 'unchanged')) order by s.start_at), '[]'::jsonb)
    into v_rows
    from public.datesheet_slot_snapshot s
   where s.version_id = v_ver.id and s.class_level_id = v_enr.class_level_id
     and exists (select 1 from app.fn_exam_subject_candidates(s.exam_subject_id) c where c.enrolment_id = p_enrolment_id);

  return jsonb_build_object(
    'has_datesheet', true, 'datesheet_id', v_ds, 'version_id', v_ver.id, 'title', v_title, 'version_no', v_ver.version_no, 'published_at', v_ver.published_at,
    'is_latest', v_ver.status = 'published', 'revised', v_ver.version_no > 1, 'note', v_ver.note,
    'versions', v_list, 'datesheets', v_dlist, 'rows', v_rows);
end;
$$;
revoke execute on function public.fn_portal_datesheet(uuid, uuid, int) from public, anon;
grant execute on function public.fn_portal_datesheet(uuid, uuid, int) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- PDF bookkeeping and the private bucket
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.record_datesheet_pdf(p_version_id uuid, p_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ver public.datesheet_version%rowtype;
begin
  select * into v_ver from public.datesheet_version where id = p_version_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'VERSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_exam_office(v_ver.campus_id);
  if p_path is null or p_path not like v_ver.tenant_id::text || '/' || v_ver.datesheet_id::text || '/%' then
    raise exception 'PATH_INVALID' using errcode = '22023';
  end if;
  update public.datesheet_version set pdf_path = p_path, pdf_generated_at = now() where id = p_version_id;
end;
$$;
revoke execute on function public.record_datesheet_pdf(uuid, text) from public, anon;
grant execute on function public.record_datesheet_pdf(uuid, text) to authenticated;

-- Private bucket, no policy on storage.objects: files are written by the
-- service-role renderer and read only through 7-day signed URLs.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('datesheets', 'datesheets', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;
