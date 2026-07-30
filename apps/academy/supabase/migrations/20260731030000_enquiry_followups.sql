-- FR-B04: assign and track enquiry follow-up tasks.
--
-- Scope cuts:
--   * Automated reassignment on HR deactivation (the AC's "all their open
--     follow-ups are reassigned to the campus admissions lead") is NOT
--     wired to a trigger. "The campus admissions lead" isn't a concept
--     that exists anywhere in this schema yet — there is no per-campus
--     single-owner designation to resolve automatically (is it the
--     Principal? A configurable setting? Whichever admissions_officer has
--     the fewest open tasks?). Guessing one under time pressure would bake
--     in a policy nobody asked for. fn_reassign_followups() below does the
--     mechanical part (move every open task from one user to another) as
--     a plain callable, ready for whatever actually decides the "who" once
--     that's a real product decision.
--   * "Overdue bucket with a count badge" and "enquiry list filters to
--     overdue in one click" are UI. my_overdue_followups() gives the exact
--     query a worklist screen needs (already indexed for it); the screen
--     itself isn't built this batch, matching every other backend-first FR
--     shipped so far without dedicated UI (FR-D09/D10/D11/D12 before the
--     Leave UI batch, FR-B06's seat-availability fix, etc).
--   * fn_close_enquiry(enquiry_id, status) is named and shaped per the
--     Notion spec, but only actually implements the one transition the AC
--     exercises: closing an open enquiry as 'lost', gated on no open
--     follow-ups. 'converted' already has its own dedicated path
--     (fn_submit_application) and isn't reimplemented here; any other
--     status is rejected rather than silently handled.
--
-- campus_id is denormalized onto admission_followup even though the
-- Notion spec's object list doesn't list it, matching every other table
-- in this schema (RLS needs it directly — deriving it via a join back to
-- admission_enquiry on every row read is the kind of thing that quietly
-- becomes a seq scan at scale).

create type public.followup_channel as enum ('call', 'whatsapp', 'sms', 'email', 'in_person');
create type public.followup_outcome as enum (
  'connected', 'no_answer', 'wrong_number', 'call_later', 'visit_scheduled', 'not_interested'
);

create table public.admission_followup (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  enquiry_id    uuid not null references public.admission_enquiry(id) on delete cascade,
  channel       public.followup_channel not null,
  due_at        timestamptz not null,
  assigned_to   uuid references public.app_user(user_id),
  outcome       public.followup_outcome,
  outcome_note  text,
  completed_at  timestamptz,
  completed_by  uuid references public.app_user(user_id),
  created_at    timestamptz not null default now(),
  created_by    uuid references public.app_user(user_id)
);

create index idx_followup_assignee_due on public.admission_followup (assigned_to, due_at) where completed_at is null;

create trigger admission_followup_audit after insert or update or delete on public.admission_followup
  for each row execute function app.tg_audit_row();

create or replace function public.create_followup(
  p_enquiry_id uuid, p_due_at timestamptz, p_channel public.followup_channel, p_assigned_to uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_id      uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_enquiry.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.admission_followup (tenant_id, campus_id, enquiry_id, channel, due_at, assigned_to, created_by)
  values (v_enquiry.tenant_id, v_enquiry.campus_id, p_enquiry_id, p_channel, p_due_at, coalesce(p_assigned_to, auth.uid()), auth.uid())
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_followup(uuid, timestamptz, public.followup_channel, uuid) from public, anon;
grant execute on function public.create_followup(uuid, timestamptz, public.followup_channel, uuid) to authenticated;

create or replace function public.fn_complete_followup(
  p_followup_id uuid, p_outcome public.followup_outcome, p_outcome_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid;
  v_completed  timestamptz;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tenant_id, completed_at into v_tenant_id, v_completed from public.admission_followup where id = p_followup_id;
  if v_tenant_id is null or v_tenant_id <> app.auth_tenant_id() then
    raise exception 'FOLLOWUP_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_completed is not null then
    raise exception 'ALREADY_COMPLETED' using errcode = '55000';
  end if;

  update public.admission_followup
     set outcome = p_outcome, outcome_note = p_outcome_note, completed_at = now(), completed_by = auth.uid()
   where id = p_followup_id;
end;
$$;

revoke execute on function public.fn_complete_followup(uuid, public.followup_outcome, text) from public, anon;
grant execute on function public.fn_complete_followup(uuid, public.followup_outcome, text) to authenticated;

create or replace function public.fn_close_enquiry(p_enquiry_id uuid, p_status public.enquiry_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_open    text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_status <> 'lost' then
    raise exception 'UNSUPPORTED_STATUS' using errcode = '22023', detail = 'only the lost transition is handled here — converted happens via fn_submit_application';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_enquiry.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select string_agg(f.channel::text || ' due ' || f.due_at::text, ', ') into v_open
    from public.admission_followup f
   where f.enquiry_id = p_enquiry_id and f.completed_at is null;
  if v_open is not null then
    raise exception 'OPEN_FOLLOWUPS_EXIST' using errcode = '55000', detail = v_open;
  end if;

  update public.admission_enquiry set status = p_status where id = p_enquiry_id;
end;
$$;

revoke execute on function public.fn_close_enquiry(uuid, public.enquiry_status) from public, anon;
grant execute on function public.fn_close_enquiry(uuid, public.enquiry_status) to authenticated;

create or replace function public.fn_reassign_followups(p_from_user uuid, p_to_user uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_to_user and tenant_id = app.auth_tenant_id()) then
    raise exception 'TARGET_USER_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.admission_followup
     set assigned_to = p_to_user
   where assigned_to = p_from_user and completed_at is null and tenant_id = app.auth_tenant_id();
  get diagnostics v_count = row_count;

  return v_count;
end;
$$;

revoke execute on function public.fn_reassign_followups(uuid, uuid) from public, anon;
grant execute on function public.fn_reassign_followups(uuid, uuid) to authenticated;

-- Exactly the query an overdue worklist needs — idx_followup_assignee_due
-- covers it. Read-only and self-scoped, safe to grant broadly.
create or replace function public.my_overdue_followups()
returns setof public.admission_followup
language sql
stable
security definer
set search_path = ''
as $$
  select * from public.admission_followup
   where assigned_to = auth.uid() and completed_at is null and due_at < now();
$$;

revoke execute on function public.my_overdue_followups() from public, anon;
grant execute on function public.my_overdue_followups() to authenticated;

alter table public.admission_followup enable row level security;

create policy followup_assignee_or_campus_lead on public.admission_followup
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()) or assigned_to = auth.uid())
  );
