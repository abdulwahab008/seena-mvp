-- FR-B09: versioned document checklist per class.
--
-- Design deviations from the FR's own Supabase Objects, documented:
--   * "class_band" is modelled as (min_class_ordinal, max_class_ordinal)
--     smallints, the exact same shape FR-E07's competency ranges already
--     use in this schema, rather than a free-text band string.
--   * No "checklist_version int" column tying admission_application back
--     to a version row. Instead admission_application gets a
--     checklist_snapshot jsonb column, frozen at fn_submit_application()
--     time with the exact [{doc_type, is_mandatory, min_count}, ...] that
--     was active that day. AC1 ("an application submitted 31 July stays
--     complete after a 1 August change, never retroactively flagged") is
--     true by construction this way — fn_checklist_completeness() always
--     reads the frozen snapshot, never a live query — rather than needing
--     a version-number join and an "as-of" argument threaded through
--     every read path.
--   * No board column exists anywhere on admission_application/enquiry
--     yet (board only appears on subject_board_code and stream today) —
--     requirement rows may still be scoped to a board, but every
--     checklist lookup in this migration passes board => null, matching
--     "board is null" (applies to all boards) requirements only. Adding
--     a real per-application board selection is a separate, larger
--     admissions-flow change, not a one-line addition here.
--
-- Document upload itself (the actual file) is out of scope — same
-- "data layer only" pattern as FR-K11/K17/K29/E10/E11: admission_
-- document_submission tracks doc_type/status/count as metadata a future
-- Storage-backed upload flow would write into, not the file itself.

create type public.document_type as enum (
  'birth_certificate', 'transfer_certificate', 'passport_photo', 'b_form', 'previous_report_card', 'medical_certificate', 'other'
);
create type public.doc_status as enum ('pending', 'uploaded', 'verified', 'rejected', 'promised');

create table public.admission_document_requirement (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  min_class_ordinal smallint not null,
  max_class_ordinal smallint not null,
  board             public.board,
  doc_type          public.document_type not null,
  is_mandatory      boolean not null default true,
  min_count         smallint not null default 1,
  effective_from    date not null default current_date,
  effective_to      date,
  created_at        timestamptz not null default now(),
  constraint chk_doc_requirement_ordinal_range check (min_class_ordinal <= max_class_ordinal),
  constraint chk_doc_requirement_date_range check (effective_to is null or effective_to > effective_from),
  constraint chk_doc_requirement_min_count check (min_count >= 1)
);

create index idx_doc_requirement_campus_active on public.admission_document_requirement (campus_id, doc_type) where effective_to is null;

create trigger doc_requirement_audit after insert or update or delete on public.admission_document_requirement
  for each row execute function app.tg_audit_row();

alter table public.admission_application add column checklist_snapshot jsonb not null default '[]'::jsonb;

create table public.admission_document_submission (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  application_id    uuid not null references public.admission_application(id) on delete cascade,
  doc_type          public.document_type not null,
  status            public.doc_status not null default 'pending',
  uploaded_count    smallint not null default 0,
  promised_deadline date,
  updated_by        uuid references public.app_user(user_id),
  updated_at        timestamptz not null default clock_timestamp(),
  constraint uq_doc_submission_app_type unique (application_id, doc_type),
  constraint chk_doc_submission_count check (uploaded_count >= 0)
);

create trigger doc_submission_audit after insert or update or delete on public.admission_document_submission
  for each row execute function app.tg_audit_row();

-- Internal: the actual "what's required right now" query, reused by both
-- the submission-time snapshot and the preview wrapper below.
create or replace function app.fn_active_checklist(p_campus_id uuid, p_class_ordinal smallint, p_board public.board, p_at date)
returns setof public.admission_document_requirement
language sql
stable
set search_path = ''
as $$
  select * from public.admission_document_requirement
   where campus_id = p_campus_id
     and p_class_ordinal between min_class_ordinal and max_class_ordinal
     and (board is null or board = p_board)
     and effective_from <= p_at
     and (effective_to is null or effective_to > p_at)
   order by doc_type;
$$;

-- AC: a new configuration closes out the prior one (same campus+doc_type
-- +board) from p_effective_from onward — the old rule keeps applying to
-- every checklist snapshot taken before that date, never rewritten.
create or replace function public.set_document_requirement(
  p_campus_id uuid, p_min_class_ordinal smallint, p_max_class_ordinal smallint, p_doc_type public.document_type,
  p_is_mandatory boolean default true, p_min_count smallint default 1, p_board public.board default null,
  p_effective_from date default current_date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_min_class_ordinal > p_max_class_ordinal then
    raise exception 'INVALID_ORDINAL_RANGE' using errcode = '23514';
  end if;
  if p_min_count < 1 then
    raise exception 'MIN_COUNT_MUST_BE_POSITIVE' using errcode = '23514';
  end if;

  update public.admission_document_requirement
     set effective_to = p_effective_from
   where tenant_id = v_tenant_id and campus_id = p_campus_id and doc_type = p_doc_type
     and board is not distinct from p_board and effective_to is null and effective_from < p_effective_from;

  insert into public.admission_document_requirement (
    tenant_id, campus_id, min_class_ordinal, max_class_ordinal, board, doc_type, is_mandatory, min_count, effective_from
  ) values (
    v_tenant_id, p_campus_id, p_min_class_ordinal, p_max_class_ordinal, p_board, p_doc_type, p_is_mandatory, p_min_count, p_effective_from
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_document_requirement(uuid, smallint, smallint, public.document_type, boolean, smallint, public.board, date) from public, anon;
grant execute on function public.set_document_requirement(uuid, smallint, smallint, public.document_type, boolean, smallint, public.board, date) to authenticated;

-- AC: a class band with nothing configured for it (e.g. Class 1, no
-- previous school to produce a transfer certificate from) simply never
-- returns that requirement — true by construction from the ordinal-range
-- filter, no special-casing needed.
create or replace function public.fn_preview_checklist(p_campus_id uuid, p_class_level_id uuid, p_board public.board default null)
returns setof public.admission_document_requirement
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_ordinal   smallint;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select ordinal into v_ordinal from public.class_level where id = p_class_level_id and tenant_id = v_tenant_id;
  if v_ordinal is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  return query select * from app.fn_active_checklist(p_campus_id, v_ordinal, p_board, current_date);
end;
$$;

revoke execute on function public.fn_preview_checklist(uuid, uuid, public.board) from public, anon;
grant execute on function public.fn_preview_checklist(uuid, uuid, public.board) to authenticated;

-- fn_submit_application() widened (same signature — no caller ripple) to
-- freeze the active checklist into the new application row.
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
  v_enquiry   public.admission_enquiry%rowtype;
  v_ordinal   smallint;
  v_group     public.academic_group;
  v_seq       int;
  v_app_no    text;
  v_app_id    uuid;
  v_checklist jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_enquiry from public.admission_enquiry where id = p_enquiry_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_enquiry.status <> 'open' then
    raise exception 'ENQUIRY_NOT_OPEN' using errcode = '55000';
  end if;

  select ordinal into v_ordinal from public.class_level where id = v_enquiry.class_applied_id;

  if v_ordinal between 10 and 13 then
    if p_group_applied is null then
      raise exception 'Group is required for classes 9-12' using errcode = '23514';
    end if;
    v_group := p_group_applied;
  else
    v_group := null;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('doc_type', doc_type, 'is_mandatory', is_mandatory, 'min_count', min_count)), '[]'::jsonb)
    into v_checklist
    from app.fn_active_checklist(v_enquiry.campus_id, v_ordinal, null, current_date);

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
    submitted_by, prev_school, prev_class_passed, checklist_snapshot
  ) values (
    app.auth_tenant_id(), v_enquiry.campus_id, v_enquiry.session_id, p_enquiry_id, v_app_no, v_enquiry.class_applied_id, v_group,
    auth.uid(), p_prev_school, p_prev_class_passed, v_checklist
  )
  returning id into v_app_id;

  update public.admission_enquiry set status = 'converted' where id = p_enquiry_id;

  return v_app_id;
end;
$$;

-- AC: a document 'promised' by the previous school within 30 days counts
-- as satisfied for offer purposes, and a follow-up task is created for
-- the deadline (reusing FR-B04's own admission_followup/create_followup —
-- no separate tracking mechanism invented here).
create or replace function public.set_document_submission(
  p_application_id uuid, p_doc_type public.document_type, p_status public.doc_status,
  p_uploaded_count smallint default null, p_promised_deadline date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_app       public.admission_application%rowtype;
  v_id        uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_app from public.admission_application where id = p_application_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (v_app.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_status = 'promised' then
    if p_promised_deadline is null then
      raise exception 'PROMISED_DEADLINE_REQUIRED' using errcode = '23514';
    end if;
    if p_promised_deadline > current_date + 30 then
      raise exception 'PROMISED_DEADLINE_TOO_FAR' using errcode = '23514';
    end if;
  end if;

  insert into public.admission_document_submission (
    tenant_id, campus_id, application_id, doc_type, status, uploaded_count, promised_deadline, updated_by
  ) values (
    v_tenant_id, v_app.campus_id, p_application_id, p_doc_type, p_status, coalesce(p_uploaded_count, 0), p_promised_deadline, auth.uid()
  )
  on conflict (application_id, doc_type) do update set
    status = excluded.status, uploaded_count = excluded.uploaded_count,
    promised_deadline = excluded.promised_deadline, updated_by = excluded.updated_by, updated_at = clock_timestamp()
  returning id into v_id;

  if p_status = 'promised' then
    perform public.create_followup(v_app.enquiry_id, p_promised_deadline::timestamptz, 'call'::public.followup_channel, auth.uid());
  end if;

  return v_id;
end;
$$;

revoke execute on function public.set_document_submission(uuid, public.document_type, public.doc_status, smallint, date) from public, anon;
grant execute on function public.set_document_submission(uuid, public.document_type, public.doc_status, smallint, date) to authenticated;

-- AC: completion is false and the missing count is exact (required minus
-- have) whenever a mandatory document isn't verified/promised/uploaded-
-- to-count.
create or replace function public.fn_checklist_completeness(p_application_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_snapshot   jsonb;
  v_item       jsonb;
  v_doc_type   public.document_type;
  v_mandatory  boolean;
  v_min_count  smallint;
  v_sub_status public.doc_status;
  v_sub_count  smallint;
  v_missing    jsonb := '[]'::jsonb;
  v_complete   boolean := true;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select checklist_snapshot into v_snapshot
    from public.admission_application where id = p_application_id and tenant_id = v_tenant_id;
  if v_snapshot is null then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  for v_item in select * from jsonb_array_elements(v_snapshot)
  loop
    v_doc_type  := (v_item ->> 'doc_type')::public.document_type;
    v_mandatory := (v_item ->> 'is_mandatory')::boolean;
    v_min_count := (v_item ->> 'min_count')::smallint;

    if not v_mandatory then
      continue;
    end if;

    v_sub_status := null;
    v_sub_count := null;
    select status, uploaded_count into v_sub_status, v_sub_count
      from public.admission_document_submission
     where application_id = p_application_id and doc_type = v_doc_type;

    if not coalesce(
      v_sub_status = 'verified' or v_sub_status = 'promised' or (v_sub_status = 'uploaded' and coalesce(v_sub_count, 0) >= v_min_count),
      false
    ) then
      v_complete := false;
      v_missing := v_missing || jsonb_build_object(
        'doc_type', v_doc_type, 'required', v_min_count, 'have', coalesce(v_sub_count, 0),
        'missing', v_min_count - coalesce(v_sub_count, 0)
      );
    end if;
  end loop;

  return jsonb_build_object('complete', v_complete, 'missing', v_missing);
end;
$$;

revoke execute on function public.fn_checklist_completeness(uuid) from public, anon;
grant execute on function public.fn_checklist_completeness(uuid) to authenticated;

alter table public.admission_document_requirement enable row level security;
alter table public.admission_document_submission enable row level security;

create policy doc_requirement_campus_read on public.admission_document_requirement
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

create policy doc_submission_campus_read on public.admission_document_submission
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
