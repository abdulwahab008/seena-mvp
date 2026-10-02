-- FR-A03: Assisted onboarding wizard — a resumable 7-step checklist that
-- gets an Owner from an empty tenant to their first enrolled student.
--
-- Scope note: campus, academic_session and class_level rows are already
-- auto-seeded by provision_tenant() (FR-A01/E01) before the wizard is ever
-- shown — the campus_details/academic_session/branding/fee_heads/
-- staff_invitations/first_student steps are each a confirm-or-do-it-
-- elsewhere checkpoint over a module that already exists (/campuses,
-- /sessions, /branding, /fees/heads, /staff, /students), not a from-
-- scratch capture form. class_structure is the one genuinely wizard-native
-- step — apply_class_preset() and its preset catalogue are new, real
-- objects, matching this FR's own "Supabase Objects" list.
--
-- Scope note 2: login is deliberately NOT gated on onboarding completion
-- (this FR's own Notes — schools buy in June, finish setup in August).
-- /onboarding is a normal nav-reachable page, not a forced redirect
-- target — dozens of existing e2e specs already assert a fresh login
-- lands on /campuses, and this FR's own AC never asks for that to change.

create type public.onboarding_step_key as enum (
  'campus_details', 'branding', 'academic_session', 'class_structure',
  'fee_heads', 'staff_invitations', 'first_student'
);
create type public.onboarding_step_status as enum ('pending', 'skipped', 'done');

create table public.onboarding_progress (
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  step_key     public.onboarding_step_key not null,
  status       public.onboarding_step_status not null default 'pending',
  completed_by uuid references auth.users(id),
  completed_at timestamptz,
  primary key (tenant_id, step_key)
);

create trigger onboarding_progress_audit after insert or update or delete on public.onboarding_progress
  for each row execute function app.tg_audit_row();

-- Global template catalogue, not tenant-scoped — same shape as
-- class_structure_preset's own listed Supabase Object.
create table public.class_structure_preset (
  code       text primary key,
  label      text not null,
  label_ur   text,
  class_rows jsonb not null
);

insert into public.class_structure_preset (code, label, label_ur, class_rows) values
  (
    'nursery_kg_1_10', 'Nursery, KG, 1-10', 'نرسری، کے جی، 1 تا 10',
    '[
      {"code":"NUR","name_en":"Nursery","board_stage":"pre_primary"},
      {"code":"KG","name_en":"Kindergarten","board_stage":"pre_primary"},
      {"code":"1","name_en":"Class 1","board_stage":"primary"},
      {"code":"2","name_en":"Class 2","board_stage":"primary"},
      {"code":"3","name_en":"Class 3","board_stage":"primary"},
      {"code":"4","name_en":"Class 4","board_stage":"primary"},
      {"code":"5","name_en":"Class 5","board_stage":"primary"},
      {"code":"6","name_en":"Class 6","board_stage":"middle"},
      {"code":"7","name_en":"Class 7","board_stage":"middle"},
      {"code":"8","name_en":"Class 8","board_stage":"middle"},
      {"code":"9","name_en":"Class 9","board_stage":"secondary"},
      {"code":"10","name_en":"Class 10","board_stage":"secondary"}
    ]'::jsonb
  ),
  (
    -- Matches seed_default_class_levels() exactly (E01) — the preset an
    -- Owner picks to keep everything provision_tenant already gave them.
    'nursery_kg_1_12', 'Nursery, KG, 1-12', 'نرسری، کے جی، 1 تا 12',
    '[
      {"code":"NUR","name_en":"Nursery","board_stage":"pre_primary"},
      {"code":"KG","name_en":"Kindergarten","board_stage":"pre_primary"},
      {"code":"1","name_en":"Class 1","board_stage":"primary"},
      {"code":"2","name_en":"Class 2","board_stage":"primary"},
      {"code":"3","name_en":"Class 3","board_stage":"primary"},
      {"code":"4","name_en":"Class 4","board_stage":"primary"},
      {"code":"5","name_en":"Class 5","board_stage":"primary"},
      {"code":"6","name_en":"Class 6","board_stage":"middle"},
      {"code":"7","name_en":"Class 7","board_stage":"middle"},
      {"code":"8","name_en":"Class 8","board_stage":"middle"},
      {"code":"9","name_en":"Class 9","board_stage":"secondary"},
      {"code":"10","name_en":"Class 10","board_stage":"secondary"},
      {"code":"11","name_en":"Class 11","board_stage":"higher_secondary"},
      {"code":"12","name_en":"Class 12","board_stage":"higher_secondary"}
    ]'::jsonb
  );

create or replace function public.seed_onboarding_progress(p_tenant_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.onboarding_progress (tenant_id, step_key)
  select p_tenant_id, e.step_key
    from unnest(enum_range(null::public.onboarding_step_key)) as e(step_key);
$$;

revoke execute on function public.seed_onboarding_progress(uuid) from public, anon, authenticated;
grant execute on function public.seed_onboarding_progress(uuid) to service_role;

-- provision_tenant (FR-A01) now also seeds the 7-step onboarding
-- checklist, same widening pattern as the roles/class-levels/message-
-- templates seed calls already added here across earlier FRs — everything
-- else in the body is unchanged.
create or replace function public.provision_tenant(p_slug text, p_legal_name text, p_owner_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_campus_id uuid;
begin
  if p_slug !~ '^[a-z0-9][a-z0-9-]{2,49}$' then
    raise exception 'TENANT_SLUG_INVALID' using errcode = '22023';
  end if;

  if exists (select 1 from public.tenant where lower(slug) = lower(p_slug)) then
    raise exception 'TENANT_SLUG_TAKEN' using errcode = '23505';
  end if;

  insert into public.tenant (slug, name, legal_name, status)
  values (p_slug, p_legal_name, p_legal_name, 'provisioning')
  returning id into v_tenant_id;

  perform public.seed_tenant_roles(v_tenant_id);
  perform public.seed_default_class_levels(v_tenant_id);
  perform public.seed_default_message_templates(v_tenant_id);
  perform public.seed_onboarding_progress(v_tenant_id);

  insert into public.campus (tenant_id, code, name)
  values (v_tenant_id, 'MAIN', p_legal_name)
  returning id into v_campus_id;

  insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
  values (
    v_tenant_id,
    v_campus_id,
    to_char(current_date, 'YYYY') || '-' || to_char(current_date + interval '1 year', 'YY'),
    date_trunc('year', current_date)::date,
    (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date,
    true,
    'active'
  );

  insert into public.tenant_invitation (tenant_id, email, app_role)
  values (v_tenant_id, p_owner_email, 'owner');

  update public.tenant set status = 'active' where id = v_tenant_id;

  return v_tenant_id;
end;
$$;

-- ── complete_onboarding_step: the only write path onto onboarding_progress
create or replace function public.complete_onboarding_step(p_step_key public.onboarding_step_key, p_status public.onboarding_step_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status = 'pending' then
    raise exception 'ONBOARDING_STATUS_INVALID' using errcode = '22023';
  end if;

  update public.onboarding_progress
     set status = p_status, completed_by = auth.uid(), completed_at = now()
   where tenant_id = app.auth_tenant_id() and step_key = p_step_key;

  if not found then
    raise exception 'ONBOARDING_STEP_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.complete_onboarding_step(public.onboarding_step_key, public.onboarding_step_status) from public, anon;
grant execute on function public.complete_onboarding_step(public.onboarding_step_key, public.onboarding_step_status) to authenticated;

-- ── apply_class_preset: idempotent — an Owner re-running it after picking
-- the wrong preset must never duplicate a class row or a section (this
-- FR's own Notes). Switching to a smaller preset deactivates the classes
-- it drops rather than deleting them (same is_active=false convention
-- class_level already uses everywhere else) so any data already hanging
-- off a dropped class survives.
create or replace function public.apply_class_preset(p_tenant_id uuid, p_campus_id uuid, p_session_id uuid, p_preset_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_class_rows  jsonb;
  v_preset_codes text[];
  v_row          jsonb;
  v_class_id     uuid;
  v_class_count  int := 0;
  v_section_count int := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_tenant_id <> app.auth_tenant_id() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = p_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = p_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select class_rows into v_class_rows from public.class_structure_preset where code = p_preset_code;
  if v_class_rows is null then
    raise exception 'PRESET_NOT_FOUND' using errcode = 'P0002';
  end if;

  select array_agg(r ->> 'code') into v_preset_codes from jsonb_array_elements(v_class_rows) as r;

  for v_row in select * from jsonb_array_elements(v_class_rows)
  loop
    insert into public.class_level (tenant_id, code, name_en, ordinal, board_stage, is_active)
    values (
      p_tenant_id,
      v_row ->> 'code',
      v_row ->> 'name_en',
      coalesce((select max(ordinal) + 1 from public.class_level where tenant_id = p_tenant_id), 0),
      v_row ->> 'board_stage',
      true
    )
    on conflict (tenant_id, code) do update
      set name_en = excluded.name_en, board_stage = excluded.board_stage, is_active = true
    returning id into v_class_id;

    v_class_count := v_class_count + 1;

    if not exists (
      select 1 from public.class_section
       where campus_id = p_campus_id and session_id = p_session_id
         and class_level_id = v_class_id and name = 'A'
    ) then
      perform public.create_section(p_campus_id, p_session_id, v_class_id, 'A', 40);
      v_section_count := v_section_count + 1;
    end if;
  end loop;

  update public.class_level
     set is_active = false
   where tenant_id = p_tenant_id
     and is_active = true
     and code <> all (v_preset_codes);

  return jsonb_build_object('class_count', v_class_count, 'sections_created', v_section_count);
end;
$$;

revoke execute on function public.apply_class_preset(uuid, uuid, uuid, text) from public, anon;
grant execute on function public.apply_class_preset(uuid, uuid, uuid, text) to authenticated;

create or replace view public.v_onboarding_summary
with (security_invoker = true) as
select
  tenant_id,
  step_key,
  status,
  completed_by,
  completed_at,
  (count(*) filter (where status <> 'pending') over (partition by tenant_id))::int as steps_resolved,
  (count(*) over (partition by tenant_id))::int as steps_total
from public.onboarding_progress;

-- ── RLS ──────────────────────────────────────────────────────────────────

alter table public.onboarding_progress enable row level security;
alter table public.class_structure_preset enable row level security;

-- No INSERT/UPDATE policy here, same as tenant's own convention — all
-- writes go through seed_onboarding_progress (service_role, at
-- provisioning) or complete_onboarding_step (SECURITY DEFINER, tenant-
-- scoped by app.auth_tenant_id() internally).
create policy onboarding_progress_tenant_read on public.onboarding_progress
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create policy class_structure_preset_read_all on public.class_structure_preset
  for select to authenticated
  using (true);
