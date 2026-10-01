-- FR-I08: sealed paper custody and access audit.
--
-- A leaked paper is a firing matter and occasionally a police matter, so the
-- value of the audit trail is legal rather than operational. Two things:
--
--   SEALED. A PUBLISHED paper's content is unreadable until the release window
--   opens: the paper's slot start minus the campus release offset
--   (exam_settings.paper_release_offset_minutes, default 120 minutes). That holds
--   for the questions (row level security on exam_paper_item) and for the files
--   (fn_request_paper_access). A paper with no scheduled slot never releases.
--   Drafts stay with their requester and the exam office: they are work in
--   progress, and every download is audited either way.
--
--   AUDITED. Every attempt to obtain a paper or its key, granted or denied, is
--   one row in exam_paper_access: user, role, IP, time, outcome, reason. The
--   table is append-only by REVOKED GRANTS (no UPDATE, DELETE or TRUNCATE for
--   authenticated, anon or service_role - a service-role job cannot bypass a
--   revoked grant the way it bypasses a policy) with immutability triggers behind
--   them for the table owner. Rows are written only by fn_request_paper_access,
--   a SECURITY DEFINER function: a client has no INSERT either, so a 'granted'
--   row cannot be forged.
--
-- The bucket "exam-papers" has no policy on storage.objects at all: no public
-- read, no direct client read. The only way out is a 15-minute signed URL issued
-- by the app after this function says granted (the route plays the role of the
-- spec's issue-paper-download-url).
--
-- Who may obtain a published paper once the window is open: the exam controller,
-- the principal, the owner (and super admin), the paper's requester, and the
-- teacher of that subject to that class. Anyone else is denied and recorded.

create table public.exam_paper_access (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  exam_paper_id uuid not null references public.exam_paper(id) on delete cascade,
  user_id       uuid not null references auth.users(id),
  user_role     text not null,
  kind          text not null check (kind in ('paper', 'key')),
  outcome       text not null check (outcome in ('granted', 'denied')),
  reason        text not null,
  ip            inet,
  accessed_at   timestamptz not null default clock_timestamp()
);
create index idx_paper_access on public.exam_paper_access (exam_paper_id, accessed_at desc);
create index idx_paper_access_user on public.exam_paper_access (user_id);
create index idx_paper_access_scope on public.exam_paper_access (tenant_id, campus_id);

alter table public.exam_paper_access enable row level security;
create policy exam_paper_access_read on public.exam_paper_access for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'exam_controller')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- Append-only, by grant. Insert is also withheld from clients: the one writer is
-- fn_request_paper_access().
revoke all on public.exam_paper_access from public, anon, authenticated, service_role;
grant select on public.exam_paper_access to authenticated, service_role;

create or replace function app.tg_exam_paper_access_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  raise exception 'the paper access log is append-only' using errcode = '42501';
end;
$$;
create trigger trg_exam_paper_access_no_update before update or delete on public.exam_paper_access
  for each row execute function app.tg_exam_paper_access_immutable();
create trigger trg_exam_paper_access_no_truncate before truncate on public.exam_paper_access
  for each statement execute function app.tg_exam_paper_access_immutable();

-- ═══════════════════════════════════════════════════════════════════════
-- The release window
-- ═══════════════════════════════════════════════════════════════════════

-- When the paper's content may first be read: the earliest slot of its exam
-- subject minus the campus offset. null when the exam has no slot yet.
create or replace function app.fn_paper_release_at(p_paper_id uuid)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select (select min(s.start_at) from public.datesheet_slot s where s.exam_subject_id = p.exam_subject_id)
         - make_interval(mins => coalesce((select x.paper_release_offset_minutes from public.exam_settings x where x.campus_id = p.campus_id), 120))
    from public.exam_paper p where p.id = p_paper_id;
$$;
revoke execute on function app.fn_paper_release_at(uuid) from public, anon, authenticated;

create or replace function app.fn_paper_window_open(p_paper_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(clock_timestamp() >= app.fn_paper_release_at(p_paper_id), false);
$$;
revoke execute on function app.fn_paper_window_open(uuid) from public, anon;
grant execute on function app.fn_paper_window_open(uuid) to authenticated;

-- The questions of a published paper are sealed. Drafts follow the paper's own
-- visibility (requester and exam office); a published paper additionally needs
-- the window to be open. (This replaces FR-I05's looser read policy.)
drop policy if exists exam_paper_item_via_paper on public.exam_paper_item;
create policy exam_paper_sealed_access on public.exam_paper_item for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and exists (select 1 from public.exam_paper p where p.id = paper_id and (p.status <> 'published' or app.fn_paper_window_open(p.id))));

-- ═══════════════════════════════════════════════════════════════════════
-- Asking for a file
-- ═══════════════════════════════════════════════════════════════════════

-- Decides, records, and (when granted) returns the storage path. Never raises
-- for a refusal: the refusal row is the point, and a raise would roll it back.
-- Returns {"granted": bool, "reason": text, "path": text|null, "release_at": ts|null,
--          "set_code": text, "access_id": uuid}.
create or replace function public.fn_request_paper_access(p_paper_id uuid, p_kind text default 'paper', p_ip text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_paper    public.exam_paper%rowtype;
  v_role     text := app.auth_role();
  v_uid      uuid := (select auth.uid());
  v_release  timestamptz;
  v_granted  boolean := false;
  v_reason   text;
  v_teaches  boolean;
  v_office   boolean := v_role in ('owner', 'super_admin', 'principal', 'exam_controller');
  v_id       uuid;
begin
  if p_kind is null or p_kind not in ('paper', 'key') then
    raise exception 'KIND_INVALID' using errcode = '22023';
  end if;
  select * into v_paper from public.exam_paper where id = p_paper_id and tenant_id = app.auth_tenant_id();
  if not found or v_uid is null then
    raise exception 'PAPER_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_release := app.fn_paper_release_at(p_paper_id);
  v_teaches := exists (
    select 1 from public.exam_subject es
      join public.class_subject cs on cs.id = es.class_subject_id
      join public.section_subject_teacher t on t.subject_id = cs.subject_id
      join public.class_section sec on sec.id = t.section_id and sec.class_level_id = cs.class_level_id and sec.session_id = cs.session_id
     where es.id = v_paper.exam_subject_id and t.staff_id = v_uid);

  if v_office and v_role not in ('owner', 'super_admin') and not (v_paper.campus_id = any (app.auth_campus_ids())) then
    v_reason := 'role_not_allowed';
  elsif not v_office and v_paper.created_by <> v_uid and not v_teaches then
    v_reason := 'role_not_allowed';
  elsif v_paper.status <> 'published' then
    -- A draft is the requester's and the exam office's work in progress.
    if v_office or v_paper.created_by = v_uid then
      v_granted := true;
      v_reason := 'draft';
    else
      v_reason := 'role_not_allowed';
    end if;
  elsif v_release is null then
    v_reason := 'no_exam_slot';
  elsif clock_timestamp() < v_release then
    v_reason := 'sealed';
  else
    v_granted := true;
    v_reason := 'window_open';
  end if;

  insert into public.exam_paper_access (tenant_id, campus_id, exam_paper_id, user_id, user_role, kind, outcome, reason, ip)
  values (v_paper.tenant_id, v_paper.campus_id, p_paper_id, v_uid, v_role, p_kind, case when v_granted then 'granted' else 'denied' end, v_reason, app.fn_parse_request_ip(p_ip))
  returning id into v_id;

  return jsonb_build_object('granted', v_granted, 'reason', v_reason, 'release_at', v_release, 'set_code', v_paper.set_code, 'access_id', v_id,
                            'path', case when v_granted then app.fn_paper_file_path(p_paper_id, p_kind) end);
end;
$$;
revoke execute on function public.fn_request_paper_access(uuid, text, text) from public, anon;
grant execute on function public.fn_request_paper_access(uuid, text, text) to authenticated;

-- When a paper releases, for the page that has to say "sealed until 07:00" without
-- recording an access attempt. Visible to whoever can see the paper row.
create or replace function public.fn_paper_release_info(p_paper_id uuid)
returns table (release_at timestamptz, window_open boolean, offset_minutes int)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() in ('parent', 'student', 'none') or not app.fn_can_see_paper(p_paper_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select app.fn_paper_release_at(p_paper_id), app.fn_paper_window_open(p_paper_id),
           coalesce((select x.paper_release_offset_minutes from public.exam_settings x where x.campus_id = p.campus_id), 120)
      from public.exam_paper p where p.id = p_paper_id;
end;
$$;
revoke execute on function public.fn_paper_release_info(uuid) from public, anon;
grant execute on function public.fn_paper_release_info(uuid) to authenticated;

-- The log of one paper, oldest first, with who and when. For the principal
-- investigating a leak.
create or replace function public.fn_paper_access_log(p_paper_id uuid)
returns table (accessed_at timestamptz, user_id uuid, user_name text, user_role text, kind text, outcome text, reason text, ip inet)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_paper public.exam_paper%rowtype;
begin
  select * into v_paper from public.exam_paper where id = p_paper_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'PAPER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'exam_controller')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_paper.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    select a.accessed_at, a.user_id, coalesce(u.full_name, 'Unknown'), a.user_role, a.kind, a.outcome, a.reason, a.ip
      from public.exam_paper_access a
      left join public.app_user u on u.user_id = a.user_id
     where a.exam_paper_id = p_paper_id
     order by a.accessed_at, a.id;
end;
$$;
revoke execute on function public.fn_paper_access_log(uuid) from public, anon;
grant execute on function public.fn_paper_access_log(uuid) to authenticated;
