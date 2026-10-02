-- FR-C01 (permanent GR number allocation) and FR-C04 (student profile).
-- Shipped together: C04's create_student() is the only caller of C01's
-- allocator, so there's no meaningful way to test one without the other.
--
-- Scope cuts (both explicitly deferred by the FRs' own Notes, not corners
-- cut here):
--   * Urdu-name-required-for-certificates and B-Form-required-at-board-
--     registration are print/registration-time gates in modules that don't
--     exist yet (Certificates, board reporting) — C04's own Notes say to
--     model both fields as nullable at admission and gate them downstream.
--   * Photo upload (2MB / 200x200px validation) needs Storage + either
--     client-side or server-side image decoding — photo_path is a bare
--     nullable text column (a storage path), no validation at the DB layer
--     since Postgres can't inspect image bytes.
--   * No UI yet: a real "admit a student" screen needs section allotment
--     (FR-C02) and guardian linkage (FR-C09/C10) alongside it, or it's just
--     a lone form that doesn't match how a Principal actually admits
--     someone. DB layer + pgTAP now; UI lands with the full admit flow.

create extension if not exists pg_trgm;

-- ── C01: gr_sequence / gr_ledger ─────────────────────────────────────────
-- Deliberately NOT a Postgres SEQUENCE: sequences are non-transactional and
-- leak values on rollback, and the GR register is cited in board
-- correspondence and legal disputes, so it must be gapless. A row-locked
-- counter serialises allocation per campus — fine at admissions volume
-- (tens/day), not fine at high-throughput.

create table public.gr_sequence (
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  campus_id  uuid not null references public.campus(id) on delete cascade,
  prefix     text not null,
  next_value bigint not null default 1,
  pad_width  int not null default 6,
  primary key (campus_id)
);

-- Every campus gets a sequence the moment it exists, seeded from its own
-- code. A school migrating from a paper register overwrites next_value via
-- set_gr_sequence() before the first real admission.
create or replace function app.tg_seed_gr_sequence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.gr_sequence (tenant_id, campus_id, prefix, next_value, pad_width)
  values (new.tenant_id, new.id, new.code, 1, 6)
  on conflict (campus_id) do nothing;
  return new;
end;
$$;

create trigger campus_seed_gr_sequence after insert on public.campus
  for each row execute function app.tg_seed_gr_sequence();

create or replace function public.set_gr_sequence(
  p_campus_id uuid, p_prefix text, p_next_value bigint, p_pad_width smallint default 6
)
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
  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.gr_sequence
     set prefix = p_prefix, next_value = p_next_value, pad_width = p_pad_width
   where campus_id = p_campus_id;
end;
$$;

revoke execute on function public.set_gr_sequence(uuid, text, bigint, smallint) from public, anon;
grant execute on function public.set_gr_sequence(uuid, text, bigint, smallint) to authenticated;

create or replace function app.fn_allocate_gr_number(p_campus_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row public.gr_sequence%rowtype;
  v_gr  text;
begin
  select * into v_row from public.gr_sequence where campus_id = p_campus_id for update;
  if not found then
    raise exception 'GR_SEQUENCE_NOT_CONFIGURED' using errcode = 'P0002';
  end if;

  v_gr := v_row.prefix || '-' || lpad(v_row.next_value::text, v_row.pad_width, '0');
  update public.gr_sequence set next_value = next_value + 1 where campus_id = p_campus_id;

  return v_gr;
end;
$$;

revoke execute on function app.fn_allocate_gr_number(uuid) from public, anon, authenticated;

create table public.gr_ledger (
  campus_id    uuid not null references public.campus(id) on delete cascade,
  gr_number    text not null,
  student_id   uuid,
  allocated_at timestamptz not null default now(),
  allocated_by uuid references public.app_user(user_id),
  primary key (campus_id, gr_number)
);

alter table public.gr_sequence enable row level security;
alter table public.gr_ledger enable row level security;

create policy gr_sequence_campus_read on public.gr_sequence
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy gr_ledger_read_campus on public.gr_ledger
  for select to authenticated
  using (campus_id in (select id from public.campus where tenant_id = app.auth_tenant_id()));

-- ── C04: student ──────────────────────────────────────────────────────

create type public.gender as enum ('male', 'female', 'other');
create type public.student_status as enum ('active', 'inactive', 'left', 'graduated', 'expelled');

create table public.student (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  campus_id            uuid not null references public.campus(id) on delete cascade,
  gr_number            text not null,
  name_en              text not null,
  name_ur              text,
  father_name_en       text,
  father_name_ur       text,
  dob                  date not null,
  gender               public.gender not null,
  religion             text,
  nationality          text not null default 'PK',
  b_form_no            text,
  bform_override_reason text,
  blood_group          text,
  photo_path           text,
  address              jsonb not null default '{}'::jsonb,
  status               public.student_status not null default 'active',
  family_group_id      uuid,
  house_id             uuid,
  no_readmission_flag  boolean not null default false,
  created_at           timestamptz not null default now(),
  constraint chk_bform_format check (b_form_no is null or b_form_no ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  constraint chk_dob_reasonable check (dob <= current_date and dob >= current_date - interval '25 years')
);

create unique index uq_student_gr on public.student (tenant_id, gr_number);
create index idx_student_bform on public.student (tenant_id, b_form_no);
create index idx_student_name_trgm on public.student using gin (name_en gin_trgm_ops);
create index idx_student_campus on public.student (campus_id);

create trigger student_audit after insert or update or delete on public.student
  for each row execute function app.tg_audit_row();

create or replace function app.tg_student_gr_number_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.gr_number <> old.gr_number then
    raise exception 'GR_NUMBER_IMMUTABLE' using errcode = '0A000';
  end if;
  return new;
end;
$$;

create trigger trg_gr_number_immutable
  before update of gr_number on public.student
  for each row execute function app.tg_student_gr_number_immutable();

create or replace function public.create_student(
  p_campus_id             uuid,
  p_name_en               text,
  p_dob                   date,
  p_gender                public.gender,
  p_name_ur               text default null,
  p_father_name_en        text default null,
  p_father_name_ur        text default null,
  p_religion              text default null,
  p_nationality           text default 'PK',
  p_b_form_no             text default null,
  p_blood_group           text default null,
  p_bform_override_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id                uuid;
  v_gr                text;
  v_normalized_bform  text;
  v_existing          record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_b_form_no is not null and btrim(p_b_form_no) <> '' then
    v_normalized_bform := regexp_replace(p_b_form_no, '[^0-9]', '', 'g');
    if length(v_normalized_bform) <> 13 then
      raise exception 'BFORM_INVALID_FORMAT' using errcode = '23514';
    end if;
    v_normalized_bform :=
      substr(v_normalized_bform, 1, 5) || '-' || substr(v_normalized_bform, 6, 7) || '-' || substr(v_normalized_bform, 13, 1);

    select id, gr_number into v_existing
      from public.student
     where tenant_id = app.auth_tenant_id() and b_form_no = v_normalized_bform
     limit 1;

    if found and p_bform_override_reason is null then
      raise exception 'BFORM_DUPLICATE'
        using errcode = '23505', detail = format('existing_gr=%s existing_student_id=%s', v_existing.gr_number, v_existing.id);
    end if;
  end if;

  v_gr := app.fn_allocate_gr_number(p_campus_id);

  insert into public.student (
    tenant_id, campus_id, gr_number, name_en, name_ur, father_name_en, father_name_ur,
    dob, gender, religion, nationality, b_form_no, blood_group, bform_override_reason
  ) values (
    app.auth_tenant_id(), p_campus_id, v_gr, p_name_en, p_name_ur, p_father_name_en, p_father_name_ur,
    p_dob, p_gender, p_religion, coalesce(p_nationality, 'PK'), v_normalized_bform, p_blood_group,
    p_bform_override_reason
  )
  returning id into v_id;

  insert into public.gr_ledger (campus_id, gr_number, student_id, allocated_by)
  values (p_campus_id, v_gr, v_id, auth.uid());

  return v_id;
end;
$$;

revoke execute on function public.create_student(
  uuid, text, date, public.gender, text, text, text, text, text, text, text, text
) from public, anon;
grant execute on function public.create_student(
  uuid, text, date, public.gender, text, text, text, text, text, text, text, text
) to authenticated;

-- gr_ledger is created before student exists (it's what allocates the GR
-- number student.gr_number then uses), so the FK is added here instead of
-- at gr_ledger's own CREATE TABLE.
alter table public.gr_ledger add constraint gr_ledger_student_fk foreign key (student_id) references public.student(id);

alter table public.student enable row level security;

create policy student_campus_scope on public.student
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
