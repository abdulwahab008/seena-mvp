-- FR-K06: concession award approval workflow, against FR-K05's scheme
-- catalogue.
--
-- Accounting-specific care: "who approved, when, on what evidence" is the
-- actual deliverable here, not the discount — hardship awards attract
-- fraud and favouritism, so every decision (approve or reject) is
-- recorded with an actor and a timestamp, and a rejection additionally
-- requires a reason of real substance (>= 10 chars, both as a friendly
-- upfront check and as chk_rejection_reason_length backstopping it).
--
-- effective_to is NOT NULL and must be strictly after effective_from —
-- the Notes call this out explicitly: an open-ended award granted in
-- class 3 is still silently running in class 10 if nothing forces an end
-- date at the point of award.
--
-- concession_award_bu_reset_status (a BEFORE UPDATE trigger, not
-- application logic in edit_concession_award) is deliberate: it means
-- ANY future code path that changes an approved award's terms forces it
-- back to pending, not just the one function that exists today.
--
-- The award-vs-scheme cross-table check FR-K05's migration explicitly
-- deferred (a plain CHECK constraint can't compare across tables) is
-- enforced here, in request_concession_award() and edit_concession_award():
-- value capped at the scheme's own max_value, and at 100 for a percentage
-- scheme regardless of max_value.
--
-- Scope cuts:
--   * Real document upload (a concession-docs Storage bucket, signed
--     URLs, an upload widget) is NOT built. concession_award_document
--     stores a storage_path reference — the requires_document gate
--     ("0 attachments -> rejected") is enforced against however many
--     paths are given, but nothing here uploads a file to actually
--     produce one yet. This app has no Storage usage anywhere yet
--     (staff photos, applicant documents — FR-B10 — are in the same
--     boat); building one bucket's worth of upload plumbing just for
--     this FR, without a broader storage strategy, would be premature.
--   * parent_read_own_child_award (from the FR's own RLS list) is not
--     implemented — there is no guardian/parent portal authentication
--     anywhere in this schema yet for it to gate.

create type public.concession_award_status as enum ('pending', 'approved', 'rejected');

create table public.concession_award (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  enrolment_id     uuid not null references public.enrolment(id) on delete cascade,
  scheme_id        uuid not null references public.concession_scheme(id),
  calc_type        public.concession_calc_type not null,
  value            numeric(10, 2) not null,
  effective_from   date not null,
  effective_to     date not null,
  status           public.concession_award_status not null default 'pending',
  requested_by     uuid references public.app_user(user_id),
  approved_by      uuid references public.app_user(user_id),
  approved_at      timestamptz,
  rejection_reason text,
  created_at       timestamptz not null default now(),
  constraint chk_award_dates check (effective_to > effective_from),
  constraint chk_rejection_reason_length check (rejection_reason is null or length(btrim(rejection_reason)) >= 10)
);

create index idx_concession_award_enrolment on public.concession_award (enrolment_id);
create index idx_concession_award_campus_status on public.concession_award (campus_id, status);

create trigger concession_award_audit after insert or update or delete on public.concession_award
  for each row execute function app.tg_audit_row();

create table public.concession_award_document (
  id            uuid primary key default gen_random_uuid(),
  award_id      uuid not null references public.concession_award(id) on delete cascade,
  storage_path  text not null,
  doc_type      text,
  uploaded_by   uuid references public.app_user(user_id),
  uploaded_at   timestamptz not null default now()
);

create index idx_concession_award_document_award on public.concession_award_document (award_id);

create or replace function app.tg_concession_award_bu_reset_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'approved' and new.status = 'approved'
     and (new.value <> old.value or new.effective_from <> old.effective_from or new.effective_to <> old.effective_to) then
    new.status := 'pending';
    new.approved_by := null;
    new.approved_at := null;
  end if;
  return new;
end;
$$;

create trigger concession_award_bu_reset_status before update on public.concession_award
  for each row execute function app.tg_concession_award_bu_reset_status();

create or replace function public.request_concession_award(
  p_enrolment_id uuid, p_scheme_id uuid, p_value numeric, p_effective_from date, p_effective_to date,
  p_document_paths text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment public.enrolment%rowtype;
  v_scheme    public.concession_scheme%rowtype;
  v_award_id  uuid;
  v_path      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_scheme from public.concession_scheme where id = p_scheme_id and tenant_id = app.auth_tenant_id() and is_active;
  if not found then
    raise exception 'CONCESSION_SCHEME_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_scheme.calc_type = 'percentage' and p_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  if v_scheme.requires_document and coalesce(array_length(p_document_paths, 1), 0) = 0 then
    raise exception 'DOCUMENT_REQUIRED' using errcode = '23514';
  end if;

  if p_effective_to <= p_effective_from then
    raise exception 'EFFECTIVE_TO_MUST_FOLLOW_FROM' using errcode = '23514';
  end if;

  insert into public.concession_award (
    tenant_id, campus_id, enrolment_id, scheme_id, calc_type, value, effective_from, effective_to, requested_by
  ) values (
    v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, p_scheme_id, v_scheme.calc_type, p_value, p_effective_from, p_effective_to, auth.uid()
  )
  returning id into v_award_id;

  foreach v_path in array p_document_paths loop
    insert into public.concession_award_document (award_id, storage_path, uploaded_by) values (v_award_id, v_path, auth.uid());
  end loop;

  return v_award_id;
end;
$$;

revoke execute on function public.request_concession_award(uuid, uuid, numeric, date, date, text[]) from public, anon;
grant execute on function public.request_concession_award(uuid, uuid, numeric, date, date, text[]) to authenticated;

create or replace function public.decide_concession_award(p_award_id uuid, p_approve boolean, p_rejection_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_award  public.concession_award%rowtype;
  v_scheme public.concession_scheme%rowtype;
begin
  select * into v_award from public.concession_award where id = p_award_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CONCESSION_AWARD_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_award.status <> 'pending' then
    raise exception 'AWARD_NOT_PENDING' using errcode = '55000';
  end if;

  select * into v_scheme from public.concession_scheme where id = v_award.scheme_id;
  if app.auth_role() not in ('super_admin', 'owner') and app.auth_role() <> v_scheme.approver_role::text then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_approve then
    update public.concession_award
       set status = 'approved', approved_by = auth.uid(), approved_at = now(), rejection_reason = null
     where id = p_award_id;
  else
    if p_rejection_reason is null or length(btrim(p_rejection_reason)) < 10 then
      raise exception 'REJECTION_REASON_TOO_SHORT' using errcode = '23514';
    end if;
    update public.concession_award
       set status = 'rejected', approved_by = auth.uid(), approved_at = now(), rejection_reason = p_rejection_reason
     where id = p_award_id;
  end if;
end;
$$;

revoke execute on function public.decide_concession_award(uuid, boolean, text) from public, anon;
grant execute on function public.decide_concession_award(uuid, boolean, text) to authenticated;

-- The only path that changes an award's terms after it's requested — the
-- reset-to-pending consequence lives in the trigger above, not here, so
-- it can't be bypassed by a future second edit path.
create or replace function public.edit_concession_award(p_award_id uuid, p_new_value numeric)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_award  public.concession_award%rowtype;
  v_scheme public.concession_scheme%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_award from public.concession_award where id = p_award_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CONCESSION_AWARD_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_scheme from public.concession_scheme where id = v_award.scheme_id;
  if v_award.calc_type = 'percentage' and p_new_value > 100 then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;
  if v_scheme.max_value is not null and p_new_value > v_scheme.max_value then
    raise exception 'VALUE_EXCEEDS_MAXIMUM' using errcode = '23514';
  end if;

  update public.concession_award set value = p_new_value where id = p_award_id;
end;
$$;

revoke execute on function public.edit_concession_award(uuid, numeric) from public, anon;
grant execute on function public.edit_concession_award(uuid, numeric) to authenticated;

alter table public.concession_award enable row level security;
alter table public.concession_award_document enable row level security;

create policy concession_award_campus_scope on public.concession_award
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy concession_award_document_read on public.concession_award_document
  for select to authenticated
  using (
    award_id in (
      select id from public.concession_award
       where tenant_id = app.auth_tenant_id()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
