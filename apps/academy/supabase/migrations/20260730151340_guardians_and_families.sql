-- FR-C09 (multiple guardians per student), FR-C10 (shared guardian dedup)
-- and FR-C08 (sibling family groups), shipped together: C10's dedup
-- functions operate on C09's guardian table, and C08's family_group finally
-- gives student.family_group_id (added as a bare column, no FK yet, back in
-- the C04 migration) something to reference.

create type public.guardian_relationship as enum (
  'father', 'mother', 'grandparent', 'uncle', 'aunt', 'sibling', 'legal_guardian', 'other'
);

-- Shared with student.b_form_no's shape (both are 13-digit Pakistani IDs
-- formatted XXXXX-XXXXXXX-X) but not factored out of create_student's
-- already-shipped, already-tested inline version — this is the first
-- second use, and create_student's logic isn't broken, so there's nothing
-- to fix there.
create or replace function app.fn_normalize_pk_id(p_raw text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_digits text;
begin
  if p_raw is null or btrim(p_raw) = '' then
    return null;
  end if;
  v_digits := regexp_replace(p_raw, '[^0-9]', '', 'g');
  if length(v_digits) <> 13 then
    raise exception 'ID_INVALID_FORMAT' using errcode = '23514';
  end if;
  return substr(v_digits, 1, 5) || '-' || substr(v_digits, 6, 7) || '-' || substr(v_digits, 13, 1);
end;
$$;

create table public.guardian (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  cnic         text,
  name_en      text not null,
  name_ur      text,
  phone_e164   text,
  alt_phone    text,
  email        text,
  occupation   text,
  auth_user_id uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  constraint chk_guardian_cnic_format check (cnic is null or cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$')
);

-- Partial on cnic is not null: roughly one guardian in twenty has none at
-- admission (expat parents, a deceased father, informal guardianship), and
-- a non-partial index would collide the second CNIC-less guardian in the
-- tenant with the first.
create unique index uq_guardian_cnic on public.guardian (tenant_id, cnic) where cnic is not null;

create trigger guardian_audit after insert or update or delete on public.guardian
  for each row execute function app.tg_audit_row();

create table public.student_guardian (
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  student_id        uuid not null references public.student(id) on delete cascade,
  guardian_id       uuid not null references public.guardian(id) on delete cascade,
  relationship      public.guardian_relationship not null,
  priority          int not null default 1,
  is_primary        boolean not null default false,
  receives_billing  boolean not null default false,
  receives_academic boolean not null default true,
  may_collect_child boolean not null default true,
  from_date         date not null default current_date,
  to_date           date,
  created_at        timestamptz not null default now(),
  primary key (student_id, guardian_id)
);

create unique index uq_primary_guardian on public.student_guardian (student_id) where is_primary and to_date is null;
create index idx_student_guardian_guardian on public.student_guardian (guardian_id);

create trigger student_guardian_audit after insert or update or delete on public.student_guardian
  for each row execute function app.tg_audit_row();

-- Immediate, not deferred: each link_guardian()/unlink_guardian() call is
-- its own PostgREST-issued transaction, so "at least one billing recipient
-- after this save" and "at least one billing recipient at commit" are the
-- same moment in practice — and an immediate trigger is what makes this
-- testable inside pgTAP's single ambient transaction (a deferred one only
-- fires at COMMIT, which a rollback-ing test never reaches).
create or replace function app.tg_require_billing_recipient()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student_id  uuid;
  v_has_billing boolean;
begin
  v_student_id := coalesce(new.student_id, old.student_id);

  select exists(
    select 1 from public.student_guardian
     where student_id = v_student_id and to_date is null and receives_billing
  ) into v_has_billing;

  if not v_has_billing then
    raise exception 'At least one guardian must receive fee notices' using errcode = '23514';
  end if;

  return null;
end;
$$;

create trigger trg_require_billing_recipient
  after insert or update or delete on public.student_guardian
  for each row execute function app.tg_require_billing_recipient();

create or replace function public.fn_find_guardian_by_cnic(p_cnic text)
returns uuid
language sql
security definer
stable
set search_path = ''
as $$
  select id from public.guardian where tenant_id = app.auth_tenant_id() and cnic = app.fn_normalize_pk_id(p_cnic);
$$;

revoke execute on function public.fn_find_guardian_by_cnic(text) from public, anon;
grant execute on function public.fn_find_guardian_by_cnic(text) to authenticated;

create or replace function public.fn_find_or_create_guardian(
  p_name_en text, p_cnic text default null, p_name_ur text default null,
  p_phone_e164 text default null, p_alt_phone text default null,
  p_email text default null, p_occupation text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_normalized_cnic text;
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_cnic is not null then
    v_normalized_cnic := app.fn_normalize_pk_id(p_cnic);
    select id into v_id from public.guardian where tenant_id = app.auth_tenant_id() and cnic = v_normalized_cnic;
    if found then
      return v_id;
    end if;
  end if;

  insert into public.guardian (tenant_id, cnic, name_en, name_ur, phone_e164, alt_phone, email, occupation)
  values (app.auth_tenant_id(), v_normalized_cnic, p_name_en, p_name_ur, p_phone_e164, p_alt_phone, p_email, p_occupation)
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.fn_find_or_create_guardian(text, text, text, text, text, text, text) from public, anon;
grant execute on function public.fn_find_or_create_guardian(text, text, text, text, text, text, text) to authenticated;

create or replace function public.link_guardian(
  p_student_id       uuid,
  p_guardian_id      uuid,
  p_relationship     public.guardian_relationship,
  p_is_primary       boolean default false,
  p_receives_billing boolean default false,
  p_receives_academic boolean default true,
  p_may_collect_child boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_current_primary text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_is_primary then
    select g.name_en into v_current_primary
      from public.student_guardian sg
      join public.guardian g on g.id = sg.guardian_id
     where sg.student_id = p_student_id and sg.is_primary and sg.to_date is null;
    if found then
      raise exception 'PRIMARY_GUARDIAN_EXISTS' using errcode = '23505', detail = format('current_primary=%s', v_current_primary);
    end if;
  end if;

  insert into public.student_guardian (
    tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing, receives_academic, may_collect_child
  ) values (
    app.auth_tenant_id(), p_student_id, p_guardian_id, p_relationship, p_is_primary, p_receives_billing, p_receives_academic, p_may_collect_child
  );
end;
$$;

revoke execute on function public.link_guardian(
  uuid, uuid, public.guardian_relationship, boolean, boolean, boolean, boolean
) from public, anon;
grant execute on function public.link_guardian(
  uuid, uuid, public.guardian_relationship, boolean, boolean, boolean, boolean
) to authenticated;

create or replace function public.unlink_guardian(p_student_id uuid, p_guardian_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- End-dated, not deleted: historical messages stay attributed to this
  -- guardian even after the relationship formally ends.
  update public.student_guardian
     set to_date = current_date
   where student_id = p_student_id and guardian_id = p_guardian_id and to_date is null;
end;
$$;

revoke execute on function public.unlink_guardian(uuid, uuid) from public, anon;
grant execute on function public.unlink_guardian(uuid, uuid) to authenticated;

create view public.v_guardian_children
with (security_invoker = true) as
select sg.guardian_id, s.id as student_id, s.name_en, s.gr_number, s.campus_id
  from public.student_guardian sg
  join public.student s on s.id = sg.student_id
 where sg.to_date is null
   and s.tenant_id = app.auth_tenant_id()
   and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any(app.auth_campus_ids()));

alter table public.guardian enable row level security;
alter table public.student_guardian enable row level security;

create policy guardian_read_if_linked_child_in_scope on public.guardian
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or exists (
        select 1 from public.student_guardian sg
        join public.student s on s.id = sg.student_id
       where sg.guardian_id = guardian.id and s.campus_id = any(app.auth_campus_ids())
      )
    )
  );

create policy student_guardian_campus_scope on public.student_guardian
  for select to authenticated
  using (
    student_id in (
      select id from public.student
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

-- ── C08: family_group ─────────────────────────────────────────────────

create table public.family_group (
  id                   uuid primary key default gen_random_uuid(),
  tenant_id            uuid not null references public.tenant(id) on delete cascade,
  father_cnic          text,
  primary_guardian_id  uuid references public.guardian(id),
  confirmed_by         uuid references public.app_user(user_id),
  confirmed_at         timestamptz,
  created_at           timestamptz not null default now()
);

create index idx_family_father_cnic on public.family_group (tenant_id, father_cnic);

alter table public.student add constraint student_family_group_fk foreign key (family_group_id) references public.family_group(id);

create trigger family_group_audit after insert or update or delete on public.family_group
  for each row execute function app.tg_audit_row();

-- Ranked over active students only, by row_number() rather than a stored
-- column, so a graduation (a status change out of 'active') shifts the
-- rank on the very next read with nothing to recompute by hand.
create view public.v_sibling_rank
with (security_invoker = true) as
select s.id as student_id, s.family_group_id,
       row_number() over (partition by s.family_group_id order by s.created_at) as sibling_rank
  from public.student s
 where s.family_group_id is not null and s.status = 'active';

create or replace function public.fn_suggest_family_group(p_cnic text)
returns table(student_id uuid, name_en text, gr_number text)
language sql
security definer
stable
set search_path = ''
as $$
  select s.id, s.name_en, s.gr_number
    from public.student s
    join public.student_guardian sg on sg.student_id = s.id and sg.to_date is null
    join public.guardian g on g.id = sg.guardian_id
   where g.tenant_id = app.auth_tenant_id()
     and g.cnic = app.fn_normalize_pk_id(p_cnic)
     and sg.relationship = 'father';
$$;

revoke execute on function public.fn_suggest_family_group(text) from public, anon;
grant execute on function public.fn_suggest_family_group(text) to authenticated;

create or replace function public.link_family_group(p_student_ids uuid[], p_father_cnic text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- Reuse an existing group if any of the given students already belongs
  -- to one, rather than always minting a fresh one.
  select family_group_id into v_group_id
    from public.student
   where id = any(p_student_ids) and family_group_id is not null
   limit 1;

  if v_group_id is null then
    insert into public.family_group (tenant_id, father_cnic)
    values (app.auth_tenant_id(), case when p_father_cnic is not null then app.fn_normalize_pk_id(p_father_cnic) end)
    returning id into v_group_id;
  end if;

  update public.student set family_group_id = v_group_id where id = any(p_student_ids);

  return v_group_id;
end;
$$;

revoke execute on function public.link_family_group(uuid[], text) from public, anon;
grant execute on function public.link_family_group(uuid[], text) to authenticated;

create or replace function public.fn_merge_family_groups(p_keep_id uuid, p_merge_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- A single nullable FK on student means membership of two groups at once
  -- is structurally impossible — the merge is just a bulk repoint.
  update public.student set family_group_id = p_keep_id where family_group_id = p_merge_id;
  delete from public.family_group where id = p_merge_id and tenant_id = app.auth_tenant_id();
end;
$$;

revoke execute on function public.fn_merge_family_groups(uuid, uuid) from public, anon;
grant execute on function public.fn_merge_family_groups(uuid, uuid) to authenticated;

create or replace function public.confirm_family_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.family_group set confirmed_by = auth.uid(), confirmed_at = now()
   where id = p_group_id and tenant_id = app.auth_tenant_id();
end;
$$;

revoke execute on function public.confirm_family_group(uuid) from public, anon;
grant execute on function public.confirm_family_group(uuid) to authenticated;

alter table public.family_group enable row level security;

create policy family_group_tenant_read on public.family_group
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
