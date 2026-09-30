-- 20260801240000 rewrote create_subject() for English-only subjects and, in
-- doing so, dropped the tenant check on p_alternate_of_subject_id added by
-- 20260731310000 (module E review fix #9). Restore it, keeping the new
-- English-fallback behaviour.
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
  if p_alternate_of_subject_id is not null
     and not exists (select 1 from public.subject where id = p_alternate_of_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'ALTERNATE_SUBJECT_NOT_FOUND' using errcode = 'P0002';
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
