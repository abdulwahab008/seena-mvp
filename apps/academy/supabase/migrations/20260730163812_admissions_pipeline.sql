-- FR-B08 (submit application), FR-B15 (issue offer) and FR-B16 (offer
-- response + auto-lapse), shipped together as one enquiry->application->
-- offer->enrolment pipeline — each stage's Supabase Objects reference the
-- previous stage's table directly, so there's no meaningful way to test
-- one in isolation.
--
-- Scope cuts:
--   * B08's checklist-completeness validation needs FR-B09 (document
--     checklist config), which doesn't exist — fn_submit_application
--     accepts a submission without checking one.
--   * B08's "open follow-ups auto-closed as converted" needs FR-B04
--     (follow-up tasks), which doesn't exist.
--   * B08's officer-read-only-vs-principal-editable distinction has no
--     edit function to gate yet — nothing writes to a submitted
--     application in this migration, so the distinction is moot for now.
--   * B15's PDF offer letter needs an Edge Function (disabled locally,
--     no live internet for Deno's bootstrap) and a document-rendering
--     stack that doesn't exist — DB layer only, no letter.
--   * B16's hourly cron isn't configured (no pg_cron extension enabled
--     locally) — fn_expire_offers() is a plain callable function, correct
--     and tested, just not wired to a schedule yet.
--   * B16's waitlist-promotion trigger needs FR-B07 (waitlist), which
--     doesn't exist — a lapsed offer frees a seat but promotes no one.

create type public.academic_group as enum ('pre_medical', 'pre_engineering', 'computer_science', 'commerce', 'arts');
create type public.application_status as enum (
  'submitted', 'under_review', 'offered', 'accepted', 'declined', 'lapsed', 'enrolled', 'rejected'
);
create type public.offer_status as enum ('issued', 'accepted', 'declined', 'lapsed');
create type public.offer_decline_reason as enum ('fee_too_high', 'chose_other_school', 'relocation', 'distance', 'other');

-- Seats available for a whole class (not a specific section — an offer is
-- issued before a section is assigned) at a campus in a session.
create or replace function app.fn_available_seats(p_class_level_id uuid, p_session_id uuid, p_campus_id uuid)
returns int
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(cs.capacity), 0)::int - (
    select count(*)::int from public.enrolment e
     where e.class_level_id = p_class_level_id and e.session_id = p_session_id and e.status = 'active'
  )
  from public.class_section cs
 where cs.class_level_id = p_class_level_id and cs.session_id = p_session_id and cs.campus_id = p_campus_id and cs.is_active;
$$;

-- ── B08: admission_application ───────────────────────────────────────

create table public.admission_application (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  enquiry_id        uuid not null references public.admission_enquiry(id),
  application_no    text,
  class_applied_id  uuid not null references public.class_level(id),
  group_applied     public.academic_group,
  status            public.application_status not null default 'submitted',
  submitted_at      timestamptz not null default now(),
  submitted_by      uuid references public.app_user(user_id),
  prev_school       text,
  prev_class_passed text,
  created_at        timestamptz not null default now()
);

create index idx_application_campus_session on public.admission_application (campus_id, session_id);

create trigger admission_application_audit after insert or update or delete on public.admission_application
  for each row execute function app.tg_audit_row();

create table public.application_no_counter (
  campus_id  uuid not null references public.campus(id) on delete cascade,
  session_id uuid not null references public.academic_session(id) on delete cascade,
  next_seq   int not null default 1,
  primary key (campus_id, session_id)
);

create or replace function public.fn_submit_application(
  p_enquiry_id uuid, p_group_applied public.academic_group default null,
  p_prev_school text default null, p_prev_class_passed text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enquiry public.admission_enquiry%rowtype;
  v_ordinal smallint;
  v_group   public.academic_group;
  v_seq     int;
  v_app_no  text;
  v_app_id  uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id;
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ordinal into v_ordinal from public.class_level where id = v_enquiry.class_applied_id;

  -- Ordinals 10-13 are classes 9-12 (see seed_default_class_levels).
  if v_ordinal between 10 and 13 then
    if p_group_applied is null then
      raise exception 'Group is required for classes 9-12' using errcode = '23514';
    end if;
    v_group := p_group_applied;
  else
    v_group := null;
  end if;

  insert into public.application_no_counter (campus_id, session_id)
  values (v_enquiry.campus_id, v_enquiry.session_id)
  on conflict (campus_id, session_id) do nothing;

  update public.application_no_counter
     set next_seq = next_seq + 1
   where campus_id = v_enquiry.campus_id and session_id = v_enquiry.session_id
  returning next_seq - 1 into v_seq;

  v_app_no := 'APP-' || to_char(now(), 'YYYY') || '-' || lpad(v_seq::text, 5, '0');

  insert into public.admission_application (
    tenant_id, campus_id, session_id, enquiry_id, application_no, class_applied_id, group_applied,
    submitted_by, prev_school, prev_class_passed
  ) values (
    app.auth_tenant_id(), v_enquiry.campus_id, v_enquiry.session_id, p_enquiry_id, v_app_no, v_enquiry.class_applied_id, v_group,
    auth.uid(), p_prev_school, p_prev_class_passed
  )
  returning id into v_app_id;

  update public.admission_enquiry set status = 'converted' where id = p_enquiry_id;

  return v_app_id;
end;
$$;

revoke execute on function public.fn_submit_application(uuid, public.academic_group, text, text) from public, anon;
grant execute on function public.fn_submit_application(uuid, public.academic_group, text, text) to authenticated;

alter table public.admission_application enable row level security;

create policy application_campus_scope on public.admission_application
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- ── B15: admission_offer ─────────────────────────────────────────────

create table public.admission_offer (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  application_id        uuid not null references public.admission_application(id) on delete cascade,
  class_level_id        uuid not null references public.class_level(id),
  section_id            uuid references public.class_section(id),
  admission_fee_amount  numeric(10, 2) not null,
  issued_by             uuid references public.app_user(user_id),
  issued_at             timestamptz not null default now(),
  expires_at            timestamptz not null,
  status                public.offer_status not null default 'issued',
  responded_at          timestamptz,
  decline_reason        public.offer_decline_reason,
  extended_by           uuid references public.app_user(user_id),
  extension_reason      text,
  created_at            timestamptz not null default now()
);

create unique index uq_offer_active_per_application on public.admission_offer (application_id) where status in ('issued', 'accepted');

create trigger admission_offer_audit after insert or update or delete on public.admission_offer
  for each row execute function app.tg_audit_row();

create or replace function public.fn_issue_offer(p_application_id uuid, p_admission_fee_amount numeric, p_valid_days int default 7)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_app      public.admission_application%rowtype;
  v_available int;
  v_offer_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_app from public.admission_application where id = p_application_id;
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_available := app.fn_available_seats(v_app.class_applied_id, v_app.session_id, v_app.campus_id);
  if v_available <= 0 then
    raise exception 'NO_SEATS_AVAILABLE'
      using errcode = '23514', detail = format('class_level_id=%s session_id=%s', v_app.class_applied_id, v_app.session_id);
  end if;

  insert into public.admission_offer (tenant_id, application_id, class_level_id, admission_fee_amount, issued_by, expires_at)
  values (
    app.auth_tenant_id(), p_application_id, v_app.class_applied_id, p_admission_fee_amount, auth.uid(),
    -- Absolute end-of-day Karachi time, computed once at issue — never a
    -- validity period re-evaluated at read time.
    ((((now() at time zone 'Asia/Karachi')::date + p_valid_days) + time '23:59:59') at time zone 'Asia/Karachi')
  )
  returning id into v_offer_id;

  update public.admission_application set status = 'offered' where id = p_application_id;

  return v_offer_id;
end;
$$;

revoke execute on function public.fn_issue_offer(uuid, numeric, int) from public, anon;
grant execute on function public.fn_issue_offer(uuid, numeric, int) to authenticated;

create or replace function public.fn_extend_offer(p_offer_id uuid, p_new_expires_at timestamptz, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.admission_offer
     set expires_at = p_new_expires_at, extended_by = auth.uid(), extension_reason = p_reason
   where id = p_offer_id and status = 'issued';

  if not found then
    raise exception 'OFFER_NOT_EXTENDABLE' using errcode = '55000';
  end if;
end;
$$;

revoke execute on function public.fn_extend_offer(uuid, timestamptz, text) from public, anon;
grant execute on function public.fn_extend_offer(uuid, timestamptz, text) to authenticated;

alter table public.admission_offer enable row level security;

create policy admission_offer_campus_scope on public.admission_offer
  for select to authenticated
  using (
    application_id in (
      select id from public.admission_application
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );

-- ── B16: response, auto-lapse, reinstatement ────────────────────────

create or replace function public.fn_respond_to_offer(
  p_offer_id uuid, p_response public.offer_status, p_decline_reason public.offer_decline_reason default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_app_id    uuid;
begin
  if p_response not in ('accepted', 'declined') then
    raise exception 'INVALID_RESPONSE' using errcode = '22023';
  end if;
  if p_response = 'declined' and p_decline_reason is null then
    raise exception 'DECLINE_REASON_REQUIRED' using errcode = '23514';
  end if;

  select tenant_id, application_id into v_tenant_id, v_app_id from public.admission_offer where id = p_offer_id;
  if v_tenant_id is null then
    raise exception 'OFFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Guarded by status = 'issued', not a read-then-write: whichever of a
  -- late acceptance and the same-hour expiry sweep lands first on this row
  -- wins, and the second update simply matches zero rows.
  update public.admission_offer
     set status = p_response, responded_at = now(), decline_reason = p_decline_reason
   where id = p_offer_id and status = 'issued';

  if not found then
    raise exception 'OFFER_NOT_RESPONDABLE' using errcode = '55000';
  end if;

  update public.admission_application
     set status = case p_response when 'accepted' then 'accepted'::public.application_status else 'declined'::public.application_status end
   where id = v_app_id;
end;
$$;

revoke execute on function public.fn_respond_to_offer(uuid, public.offer_status, public.offer_decline_reason) from public, anon;
grant execute on function public.fn_respond_to_offer(uuid, public.offer_status, public.offer_decline_reason) to authenticated;

-- Not wired to a schedule (no pg_cron locally) — logic is correct and
-- pgTAP-tested; invoke it manually or from whatever the eventual scheduler
-- is (a real cron, or an Edge Function on a timer) once one exists.
create or replace function public.fn_expire_offers()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count int;
begin
  with expired as (
    update public.admission_offer
       set status = 'lapsed'
     where status = 'issued' and expires_at < now()
    returning application_id
  )
  update public.admission_application a
     set status = 'lapsed'
    from expired
   where a.id = expired.application_id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke execute on function public.fn_expire_offers() from public, anon, authenticated;
grant execute on function public.fn_expire_offers() to service_role;

create or replace function public.fn_reinstate_offer(p_offer_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_offer     public.admission_offer%rowtype;
  v_app       public.admission_application%rowtype;
  v_available int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_offer from public.admission_offer where id = p_offer_id;
  if not found or v_offer.status <> 'lapsed' then
    raise exception 'OFFER_NOT_LAPSED' using errcode = '55000';
  end if;
  select * into v_app from public.admission_application where id = v_offer.application_id;

  v_available := app.fn_available_seats(v_app.class_applied_id, v_app.session_id, v_app.campus_id);
  if v_available <= 0 then
    raise exception 'NO_SEATS_AVAILABLE' using errcode = '23514';
  end if;

  update public.admission_offer set status = 'issued', expires_at = now() + interval '7 days' where id = p_offer_id;
  update public.admission_application set status = 'offered' where id = v_offer.application_id;
end;
$$;

revoke execute on function public.fn_reinstate_offer(uuid) from public, anon;
grant execute on function public.fn_reinstate_offer(uuid) to authenticated;
