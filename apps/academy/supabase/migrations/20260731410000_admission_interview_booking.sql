-- FR-B13: book conflict-free interview slots against a panel member's
-- calendar. btree_gist is already enabled (FR-E08's teacher_allocation
-- migration) — the exclusion constraint below is the actual authority
-- against double-booking, not the application-level pre-check inside
-- book_interview(), which exists only to name the conflicting application
-- number in the error message (the notes explicitly warn against relying
-- on a read-then-insert check alone for this exact reason).
--
-- Scope cuts:
--   * AC "slot details are sent to the parent... WhatsApp taking
--     precedence over SMS" has no messaging Edge Function in this
--     codebase — fn_build_interview_notification_payload() hands a future
--     sender the resolved channel/phone/slot details, same "data layer
--     only" pattern as every other notification-shaped AC this session
--     (FR-K11 challan render payload, FR-B11 roll slip payload).
--   * AC "a panel member on leave... a warning is shown and the booking
--     requires confirmation" is a soft block: book_interview() raises
--     PANEL_ON_LEAVE unless called with p_confirm_despite_leave => true,
--     which the UI turns into a confirm dialog rather than a hard refusal.

create type public.interview_status as enum ('scheduled', 'cancelled');

create table public.admission_interview (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  application_id uuid not null references public.admission_application(id) on delete cascade,
  panel_user_id  uuid not null references public.app_user(user_id),
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  venue          text,
  status         public.interview_status not null default 'scheduled',
  created_at     timestamptz not null default clock_timestamp(),
  during         tstzrange generated always as (tstzrange(starts_at, ends_at, '[)')) stored,
  constraint chk_interview_time check (ends_at > starts_at),
  constraint excl_interview_panel_overlap exclude using gist (panel_user_id with =, during with &&) where (status <> 'cancelled')
);

create index idx_interview_panel_day on public.admission_interview (panel_user_id, starts_at);
create index idx_interview_application on public.admission_interview (application_id);

create trigger interview_audit after insert or update or delete on public.admission_interview
  for each row execute function app.tg_audit_row();

create or replace function public.book_interview(
  p_application_id uuid,
  p_panel_user_id uuid,
  p_starts_at timestamptz,
  p_ends_at timestamptz,
  p_venue text default null,
  p_confirm_despite_leave boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_staff_id       uuid;
  v_on_leave       boolean;
  v_conflict_no    text;
  v_id             uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_ends_at <= p_starts_at then
    raise exception 'END_MUST_BE_AFTER_START' using errcode = '23514';
  end if;
  if not exists (select 1 from public.admission_application where id = p_application_id and tenant_id = v_tenant_id) then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_panel_user_id and tenant_id = v_tenant_id) then
    raise exception 'PANEL_MEMBER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select st.id into v_staff_id from public.staff st where st.user_id = p_panel_user_id and st.tenant_id = v_tenant_id;
  if v_staff_id is not null then
    select exists(
      select 1 from public.leave_application la
       where la.staff_id = v_staff_id and la.status = 'approved'
         and la.from_date <= p_ends_at::date and la.to_date >= p_starts_at::date
    ) into v_on_leave;
    if v_on_leave and not p_confirm_despite_leave then
      raise exception 'PANEL_ON_LEAVE' using errcode = '55006', detail = 'The panel member has approved leave covering this window.';
    end if;
  end if;

  select aa.application_no into v_conflict_no
    from public.admission_interview ai
    join public.admission_application aa on aa.id = ai.application_id
   where ai.panel_user_id = p_panel_user_id and ai.status <> 'cancelled'
     and ai.during && tstzrange(p_starts_at, p_ends_at, '[)')
   limit 1;
  if v_conflict_no is not null then
    raise exception 'PANEL_MEMBER_BUSY' using errcode = '23P01', detail = v_conflict_no;
  end if;

  begin
    insert into public.admission_interview (tenant_id, application_id, panel_user_id, starts_at, ends_at, venue)
    values (v_tenant_id, p_application_id, p_panel_user_id, p_starts_at, p_ends_at, p_venue)
    returning id into v_id;
  exception when exclusion_violation then
    select aa.application_no into v_conflict_no
      from public.admission_interview ai
      join public.admission_application aa on aa.id = ai.application_id
     where ai.panel_user_id = p_panel_user_id and ai.status <> 'cancelled'
       and ai.during && tstzrange(p_starts_at, p_ends_at, '[)')
     limit 1;
    raise exception 'PANEL_MEMBER_BUSY' using errcode = '23P01', detail = coalesce(v_conflict_no, 'unknown');
  end;

  return v_id;
end;
$$;

revoke execute on function public.book_interview(uuid, uuid, timestamptz, timestamptz, text, boolean) from public, anon;
grant execute on function public.book_interview(uuid, uuid, timestamptz, timestamptz, text, boolean) to authenticated;

-- AC: cancelling frees the window immediately — the exclusion
-- constraint's own WHERE clause drops a cancelled row from the active
-- set, so the very next booking into the same window needs no cleanup.
create or replace function public.cancel_interview(p_interview_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.admission_interview set status = 'cancelled' where id = p_interview_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'INTERVIEW_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.cancel_interview(uuid) from public, anon;
grant execute on function public.cancel_interview(uuid) to authenticated;

create or replace function public.fn_build_interview_notification_payload(p_interview_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_row       record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select ai.starts_at, ai.ends_at, ai.venue, aa.application_no, ae.phone_e164, ae.whatsapp_opt_in
    into v_row
    from public.admission_interview ai
    join public.admission_application aa on aa.id = ai.application_id
    join public.admission_enquiry ae on ae.id = aa.enquiry_id
   where ai.id = p_interview_id and ai.tenant_id = v_tenant_id;
  if not found then
    raise exception 'INTERVIEW_NOT_FOUND' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'interview_id', p_interview_id,
    'application_no', v_row.application_no,
    'phone', v_row.phone_e164,
    'channel', case when v_row.whatsapp_opt_in then 'whatsapp' else 'sms' end,
    'starts_at', v_row.starts_at,
    'ends_at', v_row.ends_at,
    'venue', v_row.venue
  );
end;
$$;

revoke execute on function public.fn_build_interview_notification_payload(uuid) from public, anon;
grant execute on function public.fn_build_interview_notification_payload(uuid) to authenticated;

alter table public.admission_interview enable row level security;

create policy interview_campus_scope on public.admission_interview
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or application_id in (
        select id from public.admission_application where campus_id = any(app.auth_campus_ids())
      )
    )
  );
