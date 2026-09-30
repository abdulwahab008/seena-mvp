-- Migration: 20260801240000_subject_management_and_seeding.sql
-- Description: Allow English-only subjects (make name_ur optional / fallback to name_en),
--              implement update_subject RPC, and seed standard curriculum subjects.

-- 1. Relax NOT NULL constraint on name_ur so English-only entries are valid
alter table public.subject alter column name_ur drop not null;

-- 2. Update create_subject RPC to allow omitting Urdu name and default to English name
create or replace function public.create_subject(
  p_code                    text,
  p_name_en                 text,
  p_name_ur                 text default null,
  p_subject_type            public.subject_type default 'CORE',
  p_is_examinable           boolean default true,
  p_default_max_marks       int default null,
  p_alternate_of_subject_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_name_ur text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_name_en is null or btrim(p_name_en) = '' then
    raise exception 'ENGLISH_NAME_REQUIRED' using errcode = '23514';
  end if;
  if p_code is null or btrim(p_code) = '' then
    raise exception 'CODE_REQUIRED' using errcode = '23514';
  end if;

  v_name_ur := coalesce(nullif(btrim(p_name_ur), ''), btrim(p_name_en));

  insert into public.subject (
    tenant_id, code, name_en, name_ur, subject_type, is_examinable, default_max_marks, alternate_of_subject_id
  ) values (
    app.auth_tenant_id(), upper(btrim(p_code)), btrim(p_name_en), v_name_ur, p_subject_type, p_is_examinable, p_default_max_marks, p_alternate_of_subject_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_subject(
  text, text, text, public.subject_type, boolean, int, uuid
) from public, anon;
grant execute on function public.create_subject(
  text, text, text, public.subject_type, boolean, int, uuid
) to authenticated;

-- 3. Implement update_subject RPC
create or replace function public.update_subject(
  p_id                      uuid,
  p_code                    text,
  p_name_en                 text,
  p_subject_type            public.subject_type,
  p_is_examinable           boolean,
  p_default_max_marks       int default null,
  p_name_ur                 text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name_ur text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_name_en is null or btrim(p_name_en) = '' then
    raise exception 'ENGLISH_NAME_REQUIRED' using errcode = '23514';
  end if;
  if p_code is null or btrim(p_code) = '' then
    raise exception 'CODE_REQUIRED' using errcode = '23514';
  end if;

  v_name_ur := coalesce(nullif(btrim(p_name_ur), ''), btrim(p_name_en));

  update public.subject
  set code = upper(btrim(p_code)),
      name_en = btrim(p_name_en),
      name_ur = v_name_ur,
      subject_type = p_subject_type,
      is_examinable = p_is_examinable,
      default_max_marks = p_default_max_marks
  where id = p_id and tenant_id = app.auth_tenant_id();

  if not found then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.update_subject(
  uuid, text, text, public.subject_type, boolean, int, text
) from public, anon;
grant execute on function public.update_subject(
  uuid, text, text, public.subject_type, boolean, int, text
) to authenticated;

-- 4. Seed standard school subjects for Seena Model School & College
insert into public.subject (tenant_id, code, name_en, name_ur, subject_type, is_examinable, default_max_marks)
values
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'ENG', 'English', 'English', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'URD', 'Urdu', 'Urdu', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'MTH', 'Mathematics', 'Mathematics', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'SCI', 'General Science', 'General Science', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'PHY', 'Physics', 'Physics', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'CHM', 'Chemistry', 'Chemistry', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'BIO', 'Biology', 'Biology', 'ELECTIVE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'CSC', 'Computer Science', 'Computer Science', 'ELECTIVE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'ISL', 'Islamiyat', 'Islamiyat', 'CORE', true, 100),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'PST', 'Pakistan Studies', 'Pakistan Studies', 'CORE', true, 50),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'TQR', 'Tarjuma-tul-Quran', 'Tarjuma-tul-Quran', 'CORE', true, 50),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'SST', 'Social Studies', 'Social Studies', 'CORE', true, 75),
  ('d02148d8-395a-4c3d-8bce-e948547adb05', 'ART', 'Art & Drawing', 'Art & Drawing', 'NON_EXAMINABLE', false, null)
on conflict (tenant_id, code) do nothing;
