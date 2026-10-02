-- FR-B10: upload and verify applicant documents.
--
-- This is a real Storage build, not a "data layer only" cut like every
-- prior render/notification-payload FR this session — the entire point
-- of this FR is the private bucket and its access control, so gutting
-- that would leave nothing worth building.
--
-- Deliberate scope decisions:
--   * The "Parent" actor from the FR's own actor list can't upload yet —
--     there is no parent-portal auth session anywhere in this codebase
--     (guardian portal invitation is FR-C11, not built). Only the same
--     officer-ish roles every other admissions function in this session
--     already checks can create/verify/reject/delete a document.
--   * Upload is two calls, not a signed-upload-URL flow:
--     create_admission_document() reserves the row (and therefore the
--     exact storage_path) FIRST; the caller then uploads to that path
--     with the same session's own Supabase client — the
--     admission_docs_insert_officer storage policy below requires a
--     matching admission_document row to already exist, so a client
--     can't upload to an arbitrary path. If the client-side upload then
--     fails, delete_admission_document() is the compensating action
--     (ponytail: this leaves a harmless orphaned object in a private,
--     unguessable-path bucket on that failure path, not a cleanup job —
--     upgrade path is a scheduled sweep if that ever matters in
--     practice).
--   * fn_issue_offer() is widened (same signature) to refuse
--     DOCUMENTS_INCOMPLETE via fn_application_docs_complete(), which
--     just delegates to FR-B09's own fn_checklist_completeness() —
--     an application with no configured checklist (every existing test
--     tenant) is vacuously complete, so this is not a breaking change
--     for anything built earlier this session.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('admission-docs', 'admission-docs', false, 5242880, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

create table public.admission_document (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenant(id) on delete cascade,
  application_id uuid not null references public.admission_application(id) on delete cascade,
  doc_type       public.document_type not null,
  storage_path   text not null unique,
  file_size      int not null,
  mime_type      text not null,
  uploaded_by    uuid references public.app_user(user_id),
  verified_by    uuid references public.app_user(user_id),
  verified_at    timestamptz,
  status         public.doc_status not null default 'uploaded',
  reject_reason  text,
  b_form_no      text,
  created_at     timestamptz not null default clock_timestamp(),
  constraint chk_admission_document_status check (status in ('uploaded', 'verified', 'rejected')),
  constraint chk_admission_document_bform check (b_form_no is null or b_form_no ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  constraint chk_admission_document_size check (file_size > 0 and file_size <= 5242880)
);

create index idx_admission_document_application on public.admission_document (application_id, doc_type);

create trigger admission_document_audit after insert or update or delete on public.admission_document
  for each row execute function app.tg_audit_row();

-- AC: no object path is derivable from a public identifier — application
-- number never appears here, only the internal uuid.
create or replace function public.create_admission_document(
  p_application_id uuid, p_doc_type public.document_type, p_file_size int, p_mime_type text, p_file_ext text, p_b_form_no text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_app       public.admission_application%rowtype;
  v_id        uuid := gen_random_uuid();
  v_path      text;
  v_count     smallint;
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

  -- AC: rejected server-side too, not just by the client — no row (and
  -- therefore no reserved path to upload into) is created.
  if p_file_size > 5242880 then
    raise exception 'FILE_TOO_LARGE' using errcode = '23514', detail = 'Maximum file size 5 MB';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png', 'application/pdf') then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '23514';
  end if;

  v_path := v_tenant_id::text || '/' || p_application_id::text || '/' || p_doc_type::text || '/' || v_id::text || '.' || p_file_ext;

  insert into public.admission_document (
    id, tenant_id, application_id, doc_type, storage_path, file_size, mime_type, uploaded_by, status, b_form_no
  ) values (
    v_id, v_tenant_id, p_application_id, p_doc_type, v_path, p_file_size, p_mime_type, auth.uid(), 'uploaded', p_b_form_no
  );

  select count(*) into v_count from public.admission_document
   where application_id = p_application_id and doc_type = p_doc_type and status <> 'rejected';
  perform public.set_document_submission(p_application_id, p_doc_type, 'uploaded', v_count::smallint);

  return jsonb_build_object('document_id', v_id, 'storage_path', v_path);
end;
$$;

revoke execute on function public.create_admission_document(uuid, public.document_type, int, text, text, text) from public, anon;
grant execute on function public.create_admission_document(uuid, public.document_type, int, text, text, text) to authenticated;

create or replace function public.verify_admission_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_doc       public.admission_document%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_doc from public.admission_document where id = p_document_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.admission_document set status = 'verified', verified_by = auth.uid(), verified_at = clock_timestamp() where id = p_document_id;
  perform public.set_document_submission(v_doc.application_id, v_doc.doc_type, 'verified');
end;
$$;

revoke execute on function public.verify_admission_document(uuid) from public, anon;
grant execute on function public.verify_admission_document(uuid) to authenticated;

-- AC: rejecting (with a reason) leaves the checklist item outstanding —
-- fn_checklist_completeness() only treats verified/promised/enough-
-- uploaded as satisfying a mandatory requirement, so 'rejected' already
-- falls through to incomplete with no changes needed there.
create or replace function public.reject_admission_document(p_document_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_doc       public.admission_document%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'REASON_REQUIRED' using errcode = '23514';
  end if;

  select * into v_doc from public.admission_document where id = p_document_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.admission_document
     set status = 'rejected', reject_reason = p_reason, verified_by = null, verified_at = null
   where id = p_document_id;
  perform public.set_document_submission(v_doc.application_id, v_doc.doc_type, 'rejected');
end;
$$;

revoke execute on function public.reject_admission_document(uuid, text) from public, anon;
grant execute on function public.reject_admission_document(uuid, text) to authenticated;

-- AC: a verified document can only be deleted by a Principal (or
-- owner/super_admin) — anyone else is refused. Also the compensating
-- action for a failed client-side storage upload.
create or replace function public.delete_admission_document(p_document_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid := app.auth_tenant_id();
  v_doc           public.admission_document%rowtype;
  v_count         smallint;
  v_any_verified  boolean;
  v_new_status    public.doc_status;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_doc from public.admission_document where id = p_document_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_doc.status = 'verified' and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'Only a Principal can delete a verified document.';
  end if;

  delete from public.admission_document where id = p_document_id;

  select count(*), bool_or(status = 'verified') into v_count, v_any_verified
    from public.admission_document
   where application_id = v_doc.application_id and doc_type = v_doc.doc_type and status <> 'rejected';
  v_new_status := case when v_any_verified then 'verified' when v_count > 0 then 'uploaded' else 'pending' end;
  perform public.set_document_submission(v_doc.application_id, v_doc.doc_type, v_new_status, v_count::smallint);
end;
$$;

revoke execute on function public.delete_admission_document(uuid) from public, anon;
grant execute on function public.delete_admission_document(uuid) to authenticated;

-- AC: an offer requires every mandatory document marked verified — a
-- stricter bar than fn_checklist_completeness()'s own "verified, or
-- promised, or uploaded to the required count", which FR-B09 defined
-- for general checklist tracking (an uploaded-but-not-yet-reviewed scan
-- correctly shows as "on file" there) but which this FR's own AC
-- explicitly does not accept as sufficient to actually issue an offer.
-- A 'promised' document (the previous school will send it) still
-- counts, per FR-B09's own notes ("counts as satisfied for offer
-- purposes").
create or replace function public.fn_application_docs_complete(p_application_id uuid)
returns boolean
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
  v_sub_status public.doc_status;
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
    if not v_mandatory then
      continue;
    end if;

    select status into v_sub_status
      from public.admission_document_submission
     where application_id = p_application_id and doc_type = v_doc_type;

    if v_sub_status is distinct from 'verified' and v_sub_status is distinct from 'promised' then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

revoke execute on function public.fn_application_docs_complete(uuid) from public, anon;
grant execute on function public.fn_application_docs_complete(uuid) to authenticated;

-- Widened (same signature — no caller ripple): an application with an
-- incomplete mandatory checklist can't receive an offer.
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

  select * into v_app from public.admission_application where id = p_application_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'APPLICATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if not public.fn_application_docs_complete(p_application_id) then
    raise exception 'DOCUMENTS_INCOMPLETE' using errcode = '55000';
  end if;

  v_available := app.fn_available_seats(v_app.class_applied_id, v_app.session_id, v_app.campus_id);
  if v_available <= 0 then
    raise exception 'NO_SEATS_AVAILABLE'
      using errcode = '23514', detail = format('class_level_id=%s session_id=%s', v_app.class_applied_id, v_app.session_id);
  end if;

  insert into public.admission_offer (tenant_id, application_id, class_level_id, admission_fee_amount, issued_by, expires_at)
  values (
    app.auth_tenant_id(), p_application_id, v_app.class_applied_id, p_admission_fee_amount, auth.uid(),
    ((((now() at time zone 'Asia/Karachi')::date + p_valid_days) + time '23:59:59') at time zone 'Asia/Karachi')
  )
  returning id into v_offer_id;

  update public.admission_application set status = 'offered' where id = p_application_id;

  return v_offer_id;
end;
$$;

alter table public.admission_document enable row level security;

create policy admission_document_campus_read on public.admission_document
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or application_id in (select id from public.admission_application where campus_id = any(app.auth_campus_ids()))
    )
  );

-- AC: a campus mismatch denies read access to the object itself, not
-- just the metadata row — the same campus scoping as every other
-- admissions table this session, enforced a second time at the storage
-- layer.
create policy admission_docs_read_campus on storage.objects
  for select to authenticated
  using (
    bucket_id = 'admission-docs'
    and exists (
      select 1 from public.admission_document ad
      join public.admission_application aa on aa.id = ad.application_id
      where ad.storage_path = objects.name
        and ad.tenant_id = app.auth_tenant_id()
        and (app.auth_role() in ('super_admin', 'owner') or aa.campus_id = any(app.auth_campus_ids()))
    )
  );

-- An upload can only land at a path create_admission_document() already
-- reserved — a client can't write to an arbitrary object name.
create policy admission_docs_insert_officer on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'admission-docs'
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and exists (select 1 from public.admission_document ad where ad.storage_path = objects.name and ad.tenant_id = app.auth_tenant_id())
  );

-- AC: a verified document's object can't be deleted by a non-Principal,
-- mirrored at the storage layer even though the app's own delete path
-- never calls storage.remove() today.
create policy admission_docs_no_delete_after_verify on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'admission-docs'
    and exists (
      select 1 from public.admission_document ad
      join public.admission_application aa on aa.id = ad.application_id
      where ad.storage_path = objects.name
        and ad.tenant_id = app.auth_tenant_id()
        and (ad.status <> 'verified' or app.auth_role() in ('super_admin', 'owner', 'principal'))
        and (app.auth_role() in ('super_admin', 'owner') or aa.campus_id = any(app.auth_campus_ids()))
    )
  );
