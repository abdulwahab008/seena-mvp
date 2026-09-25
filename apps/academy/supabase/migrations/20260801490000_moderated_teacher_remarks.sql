-- Migration: 20260801490000_moderated_teacher_remarks.sql
-- Module: N. Parent & Student Portal (FR-N08: Moderated teacher remarks, No. 224, P1)
-- Acceptance Criteria:
--   AC 1: Given approval is enabled and a teacher submits a remark, when the guardian loads the portal,
--         then the remark is absent until a Principal approves it, and approval makes it visible within 60 seconds.
--   AC 2: Given an approved remark, when the teacher edits it, then a new version is created with status 'pending'
--         and the previously approved version remains the visible one until the edit is approved.
--   AC 3: Given a remark is rejected, when the Principal saves the rejection, then the teacher is notified
--         with the rejection reason and the guardian never sees the text.
--   AC 4: Given a remark written in Urdu, when a guardian views it, then it renders right-to-left
--         without clipping at a 360 px viewport width.

-- ── 1. Helper function: my_student_ids ──────────────────────────────────────
create or replace function public.my_student_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select unnest(app.auth_guardian_student_ids());
$$;

grant execute on function public.my_student_ids() to authenticated, anon;

-- ── 2. Campus Portal Policy Table ───────────────────────────────────────────
create table if not exists public.campus_portal_policy (
  campus_id                   uuid primary key references public.campus(id) on delete cascade,
  tenant_id                   uuid not null references public.tenant(id) on delete cascade,
  require_remark_approval     boolean not null default true,
  min_class_for_student_login integer not null default 6,
  show_rank                   boolean not null default false,
  created_at                  timestamptz not null default clock_timestamp(),
  updated_at                  timestamptz not null default clock_timestamp()
);

create index if not exists idx_campus_portal_policy_tenant
  on public.campus_portal_policy (tenant_id);

alter table public.campus_portal_policy enable row level security;

-- Policy RLS
drop policy if exists campus_portal_policy_staff on public.campus_portal_policy;
create policy campus_portal_policy_staff on public.campus_portal_policy
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'admin')
      or campus_id = any(app.auth_campus_ids())
    )
  );

drop policy if exists campus_portal_policy_guardian on public.campus_portal_policy;
create policy campus_portal_policy_guardian on public.campus_portal_policy
  for select to authenticated
  using (
    exists (
      select 1 from public.student s
      where s.campus_id = campus_portal_policy.campus_id
        and s.id in (select public.my_student_ids())
    )
  );

-- Helper to fetch or initialize campus portal policy
create or replace function public.get_or_create_campus_portal_policy(
  p_campus_id uuid
)
returns public.campus_portal_policy
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_policy public.campus_portal_policy;
  v_tenant_id uuid;
begin
  select tenant_id into v_tenant_id from public.campus where id = p_campus_id;
  if not found then
    raise exception 'Campus not found: %', p_campus_id;
  end if;

  select * into v_policy from public.campus_portal_policy where campus_id = p_campus_id;
  if not found then
    insert into public.campus_portal_policy (campus_id, tenant_id, require_remark_approval)
    values (p_campus_id, v_tenant_id, true)
    returning * into v_policy;
  end if;

  return v_policy;
end;
$$;

grant execute on function public.get_or_create_campus_portal_policy(uuid) to authenticated;

-- ── 3. Student Remark & Versions Tables ──────────────────────────────────────
create table if not exists public.student_remark (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  student_id          uuid not null references public.student(id) on delete cascade,
  author_id           uuid not null references public.app_user(user_id) on delete cascade,
  status              text not null check (status in ('draft', 'pending', 'approved', 'rejected')) default 'pending',
  current_version_id  uuid, -- Points to the currently active/approved version visible to guardians
  created_at          timestamptz not null default clock_timestamp(),
  updated_at          timestamptz not null default clock_timestamp()
);

create index if not exists idx_student_remark_student on public.student_remark (student_id);
create index if not exists idx_student_remark_author on public.student_remark (author_id);
create index if not exists idx_student_remark_campus_status on public.student_remark (campus_id, status);

create table if not exists public.student_remark_version (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  remark_id         uuid not null references public.student_remark(id) on delete cascade,
  version_number    integer not null default 1,
  body              text not null check (trim(body) <> ''),
  language          text not null default 'en' check (language in ('en', 'ur')),
  status            text not null check (status in ('draft', 'pending', 'approved', 'rejected')) default 'pending',
  rejection_reason  text,
  moderated_by      uuid references public.app_user(user_id) on delete set null,
  moderated_at      timestamptz,
  created_by        uuid not null references public.app_user(user_id) on delete cascade,
  created_at        timestamptz not null default clock_timestamp(),
  constraint uq_remark_version unique (remark_id, version_number)
);

create index if not exists idx_remark_version_remark on public.student_remark_version (remark_id);
create index if not exists idx_remark_version_status on public.student_remark_version (status);

-- Foreign key from student_remark to current_version_id
alter table public.student_remark
  drop constraint if exists fk_student_remark_current_version;
alter table public.student_remark
  add constraint fk_student_remark_current_version
  foreign key (current_version_id)
  references public.student_remark_version(id)
  on delete set null;

-- Effective Guardian Remarks View (Security Invoker)
create or replace view public.v_guardian_student_remarks
with (security_invoker = true)
as
select
  r.id as remark_id,
  r.student_id,
  s.name_en as student_name_en,
  s.name_ur as student_name_ur,
  s.gr_number,
  c.name as campus_name,
  v.id as version_id,
  v.version_number,
  v.body,
  v.language,
  v.created_at as remark_date,
  v.moderated_at,
  u.full_name as author_name
from public.student_remark r
join public.student_remark_version v on v.id = r.current_version_id
join public.student s on s.id = r.student_id
join public.campus c on c.id = r.campus_id
left join public.app_user u on u.user_id = r.author_id
where r.status = 'approved'
  and v.status = 'approved';

grant select on public.v_guardian_student_remarks to authenticated;

-- ── 4. Moderation Log & Teacher Notifications ───────────────────────────────
create table if not exists public.remark_moderation_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  remark_id   uuid not null references public.student_remark(id) on delete cascade,
  version_id  uuid not null references public.student_remark_version(id) on delete cascade,
  action      text not null check (action in ('submitted', 'approved', 'rejected', 'auto_approved')),
  reason      text,
  actor_id    uuid not null references auth.users(id) on delete cascade,
  created_at  timestamptz not null default clock_timestamp()
);

create index if not exists idx_remark_mod_log_remark on public.remark_moderation_log (remark_id);

create table if not exists public.teacher_remark_notification (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null default app.auth_tenant_id() references public.tenant(id) on delete cascade,
  teacher_id        uuid not null references auth.users(id) on delete cascade,
  remark_id         uuid not null references public.student_remark(id) on delete cascade,
  version_id        uuid not null references public.student_remark_version(id) on delete cascade,
  student_id        uuid not null references public.student(id) on delete cascade,
  type              text not null default 'remark_rejected' check (type in ('remark_rejected', 'remark_approved')),
  rejection_reason  text,
  is_read           boolean not null default false,
  created_at        timestamptz not null default clock_timestamp()
);

create index if not exists idx_teacher_remark_notif_teacher on public.teacher_remark_notification (teacher_id, is_read);

-- ── 5. Immutability Triggers (trg_remark_version_immutable) ─────────────────
create or replace function public.fn_remark_version_immutable()
returns trigger
language plpgsql
as $$
begin
  -- AC 2 / Notes: Once approved or rejected, a version is an immutable audit record
  if old.status in ('approved', 'rejected') then
    raise exception 'Cannot modify an approved or rejected remark version (immutable audit record: PECA-2016 safety)'
      using errcode = '23514';
  end if;

  -- Content, language, version number, remark reference and author cannot be altered
  if old.body <> new.body
     or old.language <> new.language
     or old.remark_id <> new.remark_id
     or old.version_number <> new.version_number
     or old.created_by <> new.created_by then
    raise exception 'Remark version content is immutable once created. Submit a new version instead.'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_remark_version_immutable on public.student_remark_version;
create trigger trg_remark_version_immutable
  before update on public.student_remark_version
  for each row
  execute function public.fn_remark_version_immutable();

create or replace function public.fn_remark_version_prevent_delete()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('approved', 'rejected') then
    raise exception 'Cannot delete an approved or rejected remark version (immutable audit record)'
      using errcode = '23514';
  end if;
  return old;
end;
$$;

drop trigger if exists trg_remark_version_prevent_delete on public.student_remark_version;
create trigger trg_remark_version_prevent_delete
  before delete on public.student_remark_version
  for each row
  execute function public.fn_remark_version_prevent_delete();

-- ── 6. Row Level Security Policies ──────────────────────────────────────────
alter table public.student_remark enable row level security;
alter table public.student_remark_version enable row level security;
alter table public.remark_moderation_log enable row level security;
alter table public.teacher_remark_notification enable row level security;

-- student_remark RLS
drop policy if exists remark_guardian_read on public.student_remark;
create policy remark_guardian_read on public.student_remark
  for select to authenticated
  using (
    status = 'approved'
    and current_version_id is not null
    and student_id in (select public.my_student_ids())
  );

drop policy if exists remark_staff_all on public.student_remark;
create policy remark_staff_all on public.student_remark
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner', 'principal', 'admin')
      or author_id = (select auth.uid())
      or campus_id = any(app.auth_campus_ids())
    )
  );

-- student_remark_version RLS
drop policy if exists remark_version_guardian_read on public.student_remark_version;
create policy remark_version_guardian_read on public.student_remark_version
  for select to authenticated
  using (
    status = 'approved'
    and id in (
      select current_version_id
      from public.student_remark
      where status = 'approved'
        and student_id in (select public.my_student_ids())
    )
  );

drop policy if exists remark_version_staff_read on public.student_remark_version;
create policy remark_version_staff_read on public.student_remark_version
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      created_by = (select auth.uid())
      or app.auth_role() in ('super_admin', 'owner', 'principal', 'admin')
      or exists (
        select 1 from public.student_remark r
        where r.id = student_remark_version.remark_id
          and (r.campus_id = any(app.auth_campus_ids()) or r.author_id = (select auth.uid()))
      )
    )
  );

drop policy if exists remark_version_author_insert on public.student_remark_version;
create policy remark_version_author_insert on public.student_remark_version
  for insert to authenticated
  with check (
    tenant_id = app.auth_tenant_id()
    and created_by = (select auth.uid())
  );

drop policy if exists remark_version_principal_moderate on public.student_remark_version;
create policy remark_version_principal_moderate on public.student_remark_version
  for update to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admin')
  );

-- remark_moderation_log RLS
drop policy if exists remark_moderation_log_staff on public.remark_moderation_log;
create policy remark_moderation_log_staff on public.remark_moderation_log
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      actor_id = (select auth.uid())
      or app.auth_role() in ('super_admin', 'owner', 'principal', 'admin')
    )
  );

-- teacher_remark_notification RLS
drop policy if exists teacher_remark_notification_self on public.teacher_remark_notification;
create policy teacher_remark_notification_self on public.teacher_remark_notification
  for all to authenticated
  using (
    teacher_id = (select auth.uid())
    or (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'principal', 'admin'))
  );

-- ── 7. Core Workflows RPCs ──────────────────────────────────────────────────

-- 7a. Submit a new remark
create or replace function public.submit_student_remark(
  p_student_id  uuid,
  p_body        text,
  p_language    text default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student record;
  v_policy record;
  v_remark_id uuid;
  v_version_id uuid;
  v_status text;
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'UNAUTHORIZED: User must be authenticated to submit a remark';
  end if;

  select id, tenant_id, campus_id into v_student
  from public.student
  where id = p_student_id;

  if not found then
    raise exception 'Student not found: %', p_student_id;
  end if;

  -- Check campus policy for approval requirement
  select * into v_policy
  from public.campus_portal_policy
  where campus_id = v_student.campus_id;

  if v_policy.require_remark_approval is false then
    v_status := 'approved';
  else
    v_status := 'pending';
  end if;

  -- Create remark container
  insert into public.student_remark (
    tenant_id,
    campus_id,
    student_id,
    author_id,
    status
  ) values (
    v_student.tenant_id,
    v_student.campus_id,
    v_student.id,
    v_user_id,
    v_status
  ) returning id into v_remark_id;

  -- Create version 1
  insert into public.student_remark_version (
    tenant_id,
    remark_id,
    version_number,
    body,
    language,
    status,
    created_by
  ) values (
    v_student.tenant_id,
    v_remark_id,
    1,
    p_body,
    p_language,
    v_status,
    v_user_id
  ) returning id into v_version_id;

  -- If auto-approved, link current_version_id immediately
  if v_status = 'approved' then
    update public.student_remark
    set current_version_id = v_version_id,
        updated_at = clock_timestamp()
    where id = v_remark_id;

    insert into public.remark_moderation_log (
      tenant_id, remark_id, version_id, action, actor_id
    ) values (
      v_student.tenant_id, v_remark_id, v_version_id, 'auto_approved', v_user_id
    );
  else
    insert into public.remark_moderation_log (
      tenant_id, remark_id, version_id, action, actor_id
    ) values (
      v_student.tenant_id, v_remark_id, v_version_id, 'submitted', v_user_id
    );
  end if;

  return jsonb_build_object(
    'remark_id', v_remark_id,
    'version_id', v_version_id,
    'status', v_status,
    'version_number', 1
  );
end;
$$;

grant execute on function public.submit_student_remark(uuid, text, text) to authenticated;

-- 7b. Edit an existing remark (AC 2)
-- When edited: creates a new version with status 'pending'; previous approved version remains visible!
create or replace function public.edit_student_remark(
  p_remark_id  uuid,
  p_body       text,
  p_language   text default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_remark record;
  v_policy record;
  v_next_version int;
  v_new_version_id uuid;
  v_status text;
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'UNAUTHORIZED: User must be authenticated to edit a remark';
  end if;

  select * into v_remark
  from public.student_remark
  where id = p_remark_id;

  if not found then
    raise exception 'Remark not found: %', p_remark_id;
  end if;

  -- Determine next version number
  select coalesce(max(version_number), 0) + 1 into v_next_version
  from public.student_remark_version
  where remark_id = p_remark_id;

  -- Check campus policy
  select * into v_policy
  from public.campus_portal_policy
  where campus_id = v_remark.campus_id;

  if v_policy.require_remark_approval is false then
    v_status := 'approved';
  else
    v_status := 'pending';
  end if;

  -- Create new version
  insert into public.student_remark_version (
    tenant_id,
    remark_id,
    version_number,
    body,
    language,
    status,
    created_by
  ) values (
    v_remark.tenant_id,
    p_remark_id,
    v_next_version,
    p_body,
    p_language,
    v_status,
    v_user_id
  ) returning id into v_new_version_id;

  -- If policy auto-approves, switch current_version_id to this new version
  if v_status = 'approved' then
    update public.student_remark
    set current_version_id = v_new_version_id,
        status = 'approved',
        updated_at = clock_timestamp()
    where id = p_remark_id;

    insert into public.remark_moderation_log (
      tenant_id, remark_id, version_id, action, actor_id
    ) values (
      v_remark.tenant_id, p_remark_id, v_new_version_id, 'auto_approved', v_user_id
    );
  else
    -- Crucial AC 2: previously approved version remains the visible one in current_version_id!
    insert into public.remark_moderation_log (
      tenant_id, remark_id, version_id, action, actor_id
    ) values (
      v_remark.tenant_id, p_remark_id, v_new_version_id, 'submitted', v_user_id
    );
  end if;

  return jsonb_build_object(
    'remark_id', p_remark_id,
    'version_id', v_new_version_id,
    'version_number', v_next_version,
    'status', v_status,
    'current_approved_version_id', v_remark.current_version_id
  );
end;
$$;

grant execute on function public.edit_student_remark(uuid, text, text) to authenticated;

-- 7c. Moderate a remark version (Approve / Reject) (AC 1, AC 2, AC 3)
create or replace function public.moderate_student_remark(
  p_version_id  uuid,
  p_action      text, -- 'approved' or 'rejected'
  p_reason      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_version record;
  v_remark record;
  v_user_id uuid;
begin
  v_user_id := auth.uid();
  if v_user_id is null then
    raise exception 'UNAUTHORIZED: User must be authenticated to moderate a remark';
  end if;

  if p_action not in ('approved', 'rejected') then
    raise exception 'Invalid moderation action: %. Must be approved or rejected.', p_action;
  end if;

  select * into v_version
  from public.student_remark_version
  where id = p_version_id;

  if not found then
    raise exception 'Remark version not found: %', p_version_id;
  end if;

  if v_version.status in ('approved', 'rejected') then
    raise exception 'Version % has already been moderated with status %', p_version_id, v_version.status;
  end if;

  select * into v_remark
  from public.student_remark
  where id = v_version.remark_id;

  if p_action = 'approved' then
    -- Update version
    update public.student_remark_version
    set status = 'approved',
        moderated_by = v_user_id,
        moderated_at = clock_timestamp()
    where id = p_version_id;

    -- Update remark container: make this the current visible version
    update public.student_remark
    set current_version_id = p_version_id,
        status = 'approved',
        updated_at = clock_timestamp()
    where id = v_version.remark_id;

    -- Log moderation
    insert into public.remark_moderation_log (
      tenant_id, remark_id, version_id, action, actor_id
    ) values (
      v_remark.tenant_id, v_remark.id, p_version_id, 'approved', v_user_id
    );

    -- Notify teacher of approval
    insert into public.teacher_remark_notification (
      tenant_id, teacher_id, remark_id, version_id, student_id, type
    ) values (
      v_remark.tenant_id, v_version.created_by, v_remark.id, p_version_id, v_remark.student_id, 'remark_approved'
    );

  elsif p_action = 'rejected' then
    if p_reason is null or trim(p_reason) = '' then
      raise exception 'Rejection reason is mandatory when rejecting a remark';
    end if;

    -- Update version with rejection reason
    update public.student_remark_version
    set status = 'rejected',
        rejection_reason = p_reason,
        moderated_by = v_user_id,
        moderated_at = clock_timestamp()
    where id = p_version_id;

    -- If remark has no previous approved version, set remark container status to rejected
    if v_remark.current_version_id is null then
      update public.student_remark
      set status = 'rejected',
          updated_at = clock_timestamp()
      where id = v_version.remark_id;
    end if;

    -- Log moderation
    insert into public.remark_moderation_log (
      tenant_id, remark_id, version_id, action, reason, actor_id
    ) values (
      v_remark.tenant_id, v_remark.id, p_version_id, 'rejected', p_reason, v_user_id
    );

    -- AC 3: Notify teacher with the rejection reason
    insert into public.teacher_remark_notification (
      tenant_id, teacher_id, remark_id, version_id, student_id, type, rejection_reason
    ) values (
      v_remark.tenant_id, v_version.created_by, v_remark.id, p_version_id, v_remark.student_id, 'remark_rejected', p_reason
    );
  end if;

  return jsonb_build_object(
    'version_id', p_version_id,
    'remark_id', v_remark.id,
    'status', p_action,
    'reason', p_reason
  );
end;
$$;

grant execute on function public.moderate_student_remark(uuid, text, text) to authenticated;
