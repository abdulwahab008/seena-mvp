-- FR-E04 (bilingual subject catalogue) and FR-E05 (elective stream
-- definition). Shipped together: both are standalone (neither needs the
-- other), and E05 needs to add a column to class_section (E02).
--
-- Scope cuts:
--   * subject has no DELETE path (no grant, no policy) — same reasoning as
--     class_level pre-E02: class_subject (FR-E06, not built yet) is what
--     "in use" would check against. is_active=false is the only path for
--     now; swap in a real usage check when E06 ships.
--   * ALTERNATE_SUBJECT_CONFLICT (two alternate subjects both mapped into
--     one class's curriculum) is an E06 concern — alternate_of_subject_id
--     is modelled here, but nothing reads it yet.
--   * STREAM_BOARD_MISMATCH is not implemented — it needs a campus-level
--     "registered board" concept that doesn't exist anywhere in this schema
--     yet (campus has no board column). Adding one is a real, separate
--     change belonging to FR-A02/campus settings, not a one-line addition
--     to smuggle into this migration.

-- ── E04: subject ──────────────────────────────────────────────────────

create type public.subject_type as enum ('CORE', 'ELECTIVE', 'ADDITIONAL', 'NON_EXAMINABLE');
create type public.board as enum ('FBISE', 'PUNJAB', 'SINDH', 'KPK', 'BALOCHISTAN', 'AKU_EB', 'CAMBRIDGE');

create table public.subject (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null references public.tenant(id) on delete cascade,
  code                    text not null,
  name_en                 text not null,
  name_ur                 text not null,
  subject_type            public.subject_type not null default 'CORE',
  is_examinable           boolean not null default true,
  default_max_marks       int,
  alternate_of_subject_id uuid references public.subject(id),
  is_active               boolean not null default true,
  created_at              timestamptz not null default now()
);

create unique index uq_subject_tenant_code on public.subject (tenant_id, code);
create index idx_subject_tenant_active on public.subject (tenant_id, is_active);

create table public.subject_board_code (
  subject_id uuid not null references public.subject(id) on delete cascade,
  board      public.board not null,
  board_code text not null,
  primary key (subject_id, board)
);

create trigger subject_audit after insert or update or delete on public.subject
  for each row execute function app.tg_audit_row();

create or replace function public.create_subject(
  p_code                    text,
  p_name_en                 text,
  p_name_ur                 text,
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
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_name_ur is null or btrim(p_name_ur) = '' then
    raise exception 'URDU_NAME_REQUIRED' using errcode = '23514';
  end if;

  insert into public.subject (
    tenant_id, code, name_en, name_ur, subject_type, is_examinable, default_max_marks, alternate_of_subject_id
  ) values (
    app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_subject_type, p_is_examinable, p_default_max_marks, p_alternate_of_subject_id
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

create or replace function public.set_subject_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.subject set is_active = p_is_active where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.set_subject_active(uuid, boolean) from public, anon;
grant execute on function public.set_subject_active(uuid, boolean) to authenticated;

create or replace function public.set_subject_board_code(p_subject_id uuid, p_board public.board, p_board_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.subject where id = p_subject_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.subject_board_code (subject_id, board, board_code)
  values (p_subject_id, p_board, p_board_code)
  on conflict (subject_id, board) do update set board_code = excluded.board_code;
end;
$$;

revoke execute on function public.set_subject_board_code(uuid, public.board, text) from public, anon;
grant execute on function public.set_subject_board_code(uuid, public.board, text) to authenticated;

alter table public.subject enable row level security;
alter table public.subject_board_code enable row level security;

create policy subject_tenant_read on public.subject
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy subject_board_code_tenant_read on public.subject_board_code
  for select to authenticated
  using (subject_id in (select id from public.subject where tenant_id = app.auth_tenant_id()));

-- ── E05: stream ───────────────────────────────────────────────────────

create table public.stream (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  code                  text not null,
  name_en               text not null,
  name_ur               text,
  board                 public.board not null,
  applies_from_ordinal  smallint not null,
  is_active             boolean not null default true,
  created_at            timestamptz not null default now()
);

create unique index uq_stream_tenant_code on public.stream (tenant_id, code);
create index idx_stream_tenant_active on public.stream (tenant_id, is_active);

create trigger stream_audit after insert or update or delete on public.stream
  for each row execute function app.tg_audit_row();

-- A section carries at most one stream by construction (a single nullable
-- FK column, not a join table) — no separate constraint needed for that
-- part of the AC.
alter table public.class_section add column stream_id uuid references public.stream(id);

create or replace function app.tg_validate_section_stream()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_class_ordinal smallint;
  v_applies_from  smallint;
begin
  if new.stream_id is null then
    return new;
  end if;

  select ordinal into v_class_ordinal from public.class_level where id = new.class_level_id;
  select applies_from_ordinal into v_applies_from from public.stream where id = new.stream_id;

  if v_class_ordinal < v_applies_from then
    raise exception 'STREAM_NOT_OFFERED_FOR_CLASS' using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger trg_validate_section_stream
  before insert or update of stream_id, class_level_id on public.class_section
  for each row execute function app.tg_validate_section_stream();

create or replace function public.create_stream(
  p_code text, p_name_en text, p_name_ur text, p_board public.board, p_applies_from_ordinal smallint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.stream (tenant_id, code, name_en, name_ur, board, applies_from_ordinal)
  values (app.auth_tenant_id(), p_code, p_name_en, p_name_ur, p_board, p_applies_from_ordinal)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_stream(text, text, text, public.board, smallint) from public, anon;
grant execute on function public.create_stream(text, text, text, public.board, smallint) to authenticated;

create or replace function public.set_section_stream(p_section_id uuid, p_stream_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.class_section where id = p_section_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.class_section set stream_id = p_stream_id where id = p_section_id;
end;
$$;

revoke execute on function public.set_section_stream(uuid, uuid) from public, anon;
grant execute on function public.set_section_stream(uuid, uuid) to authenticated;

create or replace function public.set_stream_active(p_id uuid, p_is_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.stream set is_active = p_is_active where id = p_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'STREAM_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.set_stream_active(uuid, boolean) from public, anon;
grant execute on function public.set_stream_active(uuid, boolean) to authenticated;

create or replace function public.delete_stream(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id into v_tenant_id from public.stream where id = p_id;
  if v_tenant_id is null then
    raise exception 'STREAM_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if exists (select 1 from public.class_section where stream_id = p_id) then
    raise exception 'STREAM_IN_USE' using errcode = '23503';
  end if;

  delete from public.stream where id = p_id;
end;
$$;

revoke execute on function public.delete_stream(uuid) from public, anon;
grant execute on function public.delete_stream(uuid) to authenticated;

alter table public.stream enable row level security;

create policy stream_tenant_read on public.stream
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
