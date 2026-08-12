-- FR-T01: certificate template designer per board.
--
-- "As a Principal, I want to define the exact wording, layout and
-- letterhead of each certificate type for my board and campus, so that
-- issued documents match what the board and district education office
-- will accept."
--
-- This is the first FR of module T's certificates cluster. Five more land
-- on top of it and this schema is shaped for them; what each one is
-- expected to ADD (none of it built here) is listed at the bottom of this
-- header.
--
-- ── What already existed and is reused, not rebuilt ───────────────────
--
--   * FR-A18's branding_asset + resolve_branding(campus, type) already
--     stores and resolves the letterhead, logo, signature and stamp with
--     exactly the campus-then-tenant fallback this FR needs, in a private
--     `branding` bucket with storage policies. This FR's own suggested
--     objects named a NEW `cert-assets` bucket for "letterheads, fonts";
--     it is deliberately not created. A second bucket holding the same
--     four asset kinds under a second set of policies would be a
--     duplicate, and FR-T09 (signature/stamp on issued PDFs) needs
--     branding_asset's 'signature'/'stamp' types anyway. Fonts are not
--     stored either: FR-F15 resolves the Nastaliq face from the render
--     host and inlines it into the print HTML as a data: URI (see
--     lib/pdf/font.ts), so there is nothing for a bucket to hold.
--
--   * FR-F15's PDF machinery. The certificate preview and (later) the
--     issued certificate render server-side print HTML through headless
--     Chromium and check Nastaliq cmap coverage before rendering. That
--     module was moved out of the timetable namespace to lib/pdf/ by this
--     FR, since it is now shared; no second PDF path and no new npm
--     dependency exists.
--
-- ── Design notes ──────────────────────────────────────────────────────
--
--   * A template GROUP is identified by the 5-tuple (tenant, campus-or-
--     tenant-default, certificate_type, board_code, language). Versions
--     are rows inside that group; at most one may be 'active'
--     (uq_template_active). campus_id NULL means "the tenant's default,
--     used by any campus that has none of its own" — AC3 — and the
--     coalesce() in both unique indexes is what lets a campus-specific
--     and a tenant-default template of the same type coexist, since a
--     plain NULL column would make every tenant-default row distinct from
--     every other.
--
--   * board_code is nullable, meaning "any board". A Transfer Certificate
--     is a board document and gets 'FBISE'/'BISE-LHR'/...; a bonafide or
--     character certificate usually is not, and a school should not have
--     to invent a board code to author one. resolve_certificate_template()
--     therefore falls back on two axes at once, most specific first:
--     campus+board → campus+any-board → tenant+board → tenant+any-board.
--     One ORDER BY, not four queries.
--
--   * Language does NOT fall back. A request for an Urdu certificate must
--     never silently produce an English one; resolve returns NULL and the
--     caller decides.
--
--   * AC2's "a new row v4 is inserted, v3 stays active" is a TRIGGER, not
--     a convention in an RPC. trg_template_version_bump intercepts any
--     UPDATE that changes the wording of a non-draft row, forks it into a
--     fresh draft version and CANCELS the update, so the active row that
--     issued certificates point at is immutable by every path — RPC,
--     PostgREST, psql. save_certificate_template() is only the ergonomic
--     wrapper that reports which row the edit actually landed on. The
--     matching BEFORE DELETE guard refuses to delete anything but a
--     draft, for the same reason: FR-T03's certificate_issue.template_id
--     will reference these rows as evidence of what was printed.
--
--   * The merge-field whitelist is two things with two jobs.
--     certificate_type_field_catalog is the PRODUCT-level whitelist: the
--     complete set of field paths the renderer can actually resolve for a
--     given certificate type, plus which of them a document of that type
--     must contain, plus a sample value per language so a template can be
--     previewed before a single certificate exists. It is global, not
--     tenant-scoped — it describes what this software can merge, not what
--     a school may write. certificate_template.merge_field_whitelist is
--     the per-version FROZEN record of the fields that version actually
--     uses, written by activate_certificate_template() once validation
--     passes, so FR-T03 knows what to resolve without re-parsing HTML and
--     a later catalog change cannot retroactively alter an active
--     template.
--
--   * AC1's rejection is enforced in activate_certificate_template(), not
--     at insert/update time: a draft is a work in progress and may name a
--     field that does not exist yet. validate_certificate_template() is
--     the same check exposed as a pure read so the designer UI can show
--     the offending field before the Principal clicks Activate, and so
--     the failure is assertable without depending on an exception's
--     DETAIL surviving PostgREST.
--
-- ── What the rest of the cluster adds (NOT built here) ────────────────
--
--   * FR-T02 (gapless serial allocation): certificate_serial_counter
--     (tenant, campus, certificate_type, session, next_serial) and
--     allocate_certificate_serial(), a row-locked allocator. The
--     'issue.serial_no' field path is already in this catalog and already
--     REQUIRED on transfer templates, so a TC authored today prints the
--     serial the moment T02 can allocate one.
--   * FR-T03 (Transfer Certificate issuance): the certificate_issue table
--     — tenant/campus/student/enrolment, certificate_type, template_id
--     referencing certificate_template(id) (AC3's "records template_id on
--     the issued row"), serial_no, issued_at/by and the resolved merge
--     values. It calls resolve_certificate_template() rather than picking
--     a template itself.
--   * FR-T05 (Character Certificate issuance): reuses certificate_issue
--     with certificate_type='character' and this catalog's own
--     character.* fields.
--   * FR-T08 (statutory register with immutability): reads
--     certificate_issue as the bound register and adds its own
--     immutability triggers; it depends on the guarantee made here that an
--     activated template version is never mutated and never deleted.
--   * FR-T09 (digital signature/stamp): adds pdf_sha256 and
--     signing_identity_id to certificate_issue and renders through
--     lib/pdf/render.ts with FR-A18's 'signature'/'stamp' branding assets.
--
-- Note for those agents: every function below that takes optional
-- arguments already has its full signature fixed. Adding a defaulted
-- argument to one of them with CREATE OR REPLACE creates a DISTINCT
-- overload and makes existing calls ambiguous (FR-G05 hit exactly this) —
-- drop and recreate, and re-issue the grants.

create type public.certificate_type as enum ('transfer', 'character', 'bonafide');
create type public.certificate_template_status as enum ('draft', 'active', 'retired');
create type public.certificate_language as enum ('en', 'ur');
create type public.certificate_page_size as enum ('A4', 'A5', 'Legal');

-- ═══════════════════════════════════════════════════════════════════════
-- The product-level merge-field whitelist
-- ═══════════════════════════════════════════════════════════════════════

create table public.certificate_type_field_catalog (
  certificate_type public.certificate_type not null,
  field_path       text not null,
  required         boolean not null default false,
  label_en         text not null,
  -- Sample values exist so a template can be previewed as a real PDF
  -- before any student has ever been issued one. sample_ur is what makes
  -- AC4 testable on a template that has not been filled in yet: an Urdu
  -- template previews with Urdu content, so the Nastaliq coverage check
  -- has something to check.
  sample_en        text not null,
  sample_ur        text,
  primary key (certificate_type, field_path),
  constraint chk_field_path_shape check (field_path ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$')
);

alter table public.certificate_type_field_catalog enable row level security;

-- Global catalogue, no tenant column: it describes what this software can
-- merge. Readable by every signed-in user, writable by nobody but a
-- migration.
create policy cert_field_catalog_read on public.certificate_type_field_catalog
  for select to authenticated using (true);
revoke insert, update, delete on public.certificate_type_field_catalog from authenticated, anon;

insert into public.certificate_type_field_catalog (certificate_type, field_path, required, label_en, sample_en, sample_ur)
select t.ct,
       f.field_path,
       f.field_path = any(case t.ct
         when 'transfer' then array['student.name_en', 'student.gr_number', 'issue.date', 'issue.serial_no', 'enrolment.left_on']
         when 'character' then array['student.name_en', 'student.gr_number', 'issue.date']
         else array['student.name_en', 'issue.date']
       end),
       f.label_en, f.sample_en, f.sample_ur
  from (values ('transfer'::public.certificate_type), ('character'), ('bonafide')) as t(ct)
  cross join (values
    ('school.name_en',         'School name',              'Seena Model High School',    'سینا ماڈل ہائی اسکول'),
    ('school.name_ur',         'School name (Urdu)',       'سینا ماڈل ہائی اسکول',        'سینا ماڈل ہائی اسکول'),
    ('campus.name',            'Campus',                   'Main Campus',                'مرکزی کیمپس'),
    ('campus.code',            'Campus code',              'MAIN',                       'MAIN'),
    ('issue.date',             'Date of issue',            '12 August 2026',             '۱۲ اگست ۲۰۲۶'),
    ('issue.serial_no',        'Certificate serial no.',   'TC-2026-000147',             'TC-2026-000147'),
    ('issue.place',            'Place of issue',           'Lahore',                     'لاہور'),
    ('student.name_en',        'Student name',             'Ahmed Raza',                 'احمد رضا'),
    ('student.name_ur',        'Student name (Urdu)',      'احمد رضا',                    'احمد رضا'),
    ('student.father_name_en', 'Father name',              'Muhammad Raza',              'محمد رضا'),
    ('student.father_name_ur', 'Father name (Urdu)',       'محمد رضا',                    'محمد رضا'),
    ('student.gr_number',      'GR number',                'GR-001482',                  'GR-001482'),
    ('student.dob',            'Date of birth',            '04 March 2012',              '۴ مارچ ۲۰۱۲'),
    ('student.dob_words',      'Date of birth in words',   'Fourth March Two Thousand Twelve', 'چار مارچ دو ہزار بارہ'),
    ('student.gender',         'Gender',                   'Male',                       'مرد'),
    ('student.religion',       'Religion',                 'Islam',                      'اسلام'),
    ('student.b_form_no',      'B-Form number',            '35202-1234567-1',            '35202-1234567-1'),
    ('enrolment.class_name',   'Class',                    'Class 8',                    'جماعت ہشتم'),
    ('enrolment.section_name', 'Section',                  'A',                          'الف'),
    ('enrolment.session_name', 'Academic session',         '2025-2026',                  '۲۰۲۵-۲۰۲۶'),
    ('enrolment.joined_on',    'Date of admission',        '01 April 2021',              '۱ اپریل ۲۰۲۱'),
    ('signatory.name',         'Signatory name',           'Farhat Jabeen',              'فرحت جبیں'),
    ('signatory.designation',  'Signatory designation',    'Principal',                  'پرنسپل')
  ) as f(field_path, label_en, sample_en, sample_ur);

insert into public.certificate_type_field_catalog (certificate_type, field_path, required, label_en, sample_en, sample_ur)
values
  ('transfer',  'enrolment.left_on',           true,  'Date of leaving',        '31 July 2026',              '۳۱ جولائی ۲۰۲۶'),
  ('transfer',  'transfer.reason',             false, 'Reason for leaving',     'Family relocation',         'خاندان کی منتقلی'),
  ('transfer',  'transfer.last_class_studied', false, 'Last class studied',     'Class 8',                   'جماعت ہشتم'),
  ('transfer',  'transfer.conduct',            false, 'Conduct',                'Good',                      'اچھا'),
  ('transfer',  'transfer.dues_cleared',       false, 'Dues cleared',           'Yes',                       'جی ہاں'),
  ('transfer',  'transfer.remarks',            false, 'Remarks',                'Promoted to Class 9',       'جماعت نہم میں ترقی'),
  ('character', 'character.conduct',           false, 'Conduct',                'Excellent',                 'بہترین'),
  ('character', 'character.remarks',           false, 'Remarks',                'Bore an excellent character', 'کردار بہترین رہا'),
  ('bonafide',  'bonafide.purpose',            false, 'Purpose',                'Passport application',      'پاسپورٹ کی درخواست');

-- ═══════════════════════════════════════════════════════════════════════
-- certificate_template
-- ═══════════════════════════════════════════════════════════════════════

create table public.certificate_template (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenant(id) on delete cascade,
  -- NULL = the tenant's default for this type/board/language (AC3).
  campus_id             uuid references public.campus(id) on delete cascade,
  certificate_type      public.certificate_type not null,
  -- NULL = applies to any board.
  board_code            text,
  language              public.certificate_language not null default 'en',
  version               int not null check (version > 0),
  title                 text not null,
  body_html             text not null,
  merge_field_whitelist jsonb not null default '[]'::jsonb,
  page_size             public.certificate_page_size not null default 'A4',
  status                public.certificate_template_status not null default 'draft',
  activated_at          timestamptz,
  activated_by          uuid references public.app_user(user_id),
  created_by            uuid references public.app_user(user_id),
  created_at            timestamptz not null default clock_timestamp(),
  constraint chk_cert_template_board check (board_code is null or board_code ~ '^[A-Z0-9][A-Z0-9-]{1,23}$'),
  constraint chk_cert_template_whitelist check (jsonb_typeof(merge_field_whitelist) = 'array'),
  constraint chk_cert_template_activation check (
    (status = 'draft' and activated_at is null) or (status <> 'draft' and activated_at is not null)
  )
);

-- The tenant-default sentinel. A literal all-zero uuid rather than a NULL,
-- so every tenant-default row of a group collides with every other one
-- exactly as a campus-specific row does — NULLs are distinct in a unique
-- index and would let two "the tenant default" templates both exist.
create unique index uq_template_version on public.certificate_template (
  tenant_id, coalesce(campus_id, '00000000-0000-0000-0000-000000000000'::uuid),
  certificate_type, coalesce(board_code, ''), language, version
);

create unique index uq_template_active on public.certificate_template (
  tenant_id, coalesce(campus_id, '00000000-0000-0000-0000-000000000000'::uuid),
  certificate_type, coalesce(board_code, ''), language
) where status = 'active';

create index idx_cert_template_resolve on public.certificate_template (tenant_id, certificate_type, language)
  where status = 'active';
create index idx_cert_template_tenant_campus on public.certificate_template (tenant_id, campus_id);

create trigger certificate_template_audit after insert or update or delete on public.certificate_template
  for each row execute function app.tg_audit_row();

alter table public.certificate_template enable row level security;

create policy cert_template_tenant_scope on public.certificate_template
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or campus_id is null
      or campus_id = any(app.auth_campus_ids())
    )
  );

-- A Principal may author their own campus's templates; only an Owner or
-- Super Admin may author the TENANT DEFAULT that every other campus falls
-- back to. Same NULL-campus reasoning as FR-A12/b16ba25: without the
-- explicit branch a campus-scoped role could pass campus_id = NULL and
-- escape the scope check entirely, since `NULL = any(...)` is NULL.
create policy cert_template_write_admin on public.certificate_template
  for all to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and case
          when campus_id is null then app.auth_role() in ('super_admin', 'owner')
          else app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())
        end
  )
  with check (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and case
          when campus_id is null then app.auth_role() in ('super_admin', 'owner')
          else app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())
        end
  );

-- ═══════════════════════════════════════════════════════════════════════
-- Immutability of an activated version
-- ═══════════════════════════════════════════════════════════════════════

-- AC2. Any UPDATE that changes the WORDING of a row that is no longer a
-- draft is turned into a new draft version and cancelled, whoever issues
-- it. Status transitions (draft→active, active→retired) and the
-- whitelist that activation freezes are not wording and pass through.
create or replace function app.tg_certificate_template_version_bump()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_next int;
begin
  if old.status = 'draft' then
    return new;
  end if;

  if new.title is not distinct from old.title
     and new.body_html is not distinct from old.body_html
     and new.page_size is not distinct from old.page_size
     and new.merge_field_whitelist is not distinct from old.merge_field_whitelist then
    return new;
  end if;

  select coalesce(max(version), 0) + 1 into v_next
    from public.certificate_template
   where tenant_id = old.tenant_id
     and campus_id is not distinct from old.campus_id
     and certificate_type = old.certificate_type
     and board_code is not distinct from old.board_code
     and language = old.language;

  insert into public.certificate_template (
    tenant_id, campus_id, certificate_type, board_code, language, version,
    title, body_html, page_size, status, created_by
  ) values (
    old.tenant_id, old.campus_id, old.certificate_type, old.board_code, old.language, v_next,
    new.title, new.body_html, new.page_size, 'draft', (select auth.uid())
  );

  -- Cancelling the UPDATE is the point: v3 keeps its wording and its
  -- 'active' status, and every certificate already issued against it
  -- still renders from exactly the bytes it was issued from.
  return null;
end;
$$;

create trigger trg_template_version_bump
  before update on public.certificate_template
  for each row execute function app.tg_certificate_template_version_bump();

create or replace function app.tg_certificate_template_no_delete_activated()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status <> 'draft' then
    raise exception 'TEMPLATE_NOT_DELETABLE'
      using errcode = '55000',
            detail = format('status=%s', old.status),
            hint = 'An activated version is the evidence of what an issued certificate said; retire it instead.';
  end if;
  return old;
end;
$$;

create trigger trg_template_no_delete_activated
  before delete on public.certificate_template
  for each row execute function app.tg_certificate_template_no_delete_activated();

-- ═══════════════════════════════════════════════════════════════════════
-- Merge-field extraction and validation
-- ═══════════════════════════════════════════════════════════════════════

-- Deliberately matches ANY {{...}} token, not only well-formed field
-- paths: a typo like {{ student name }} has to come back as an unknown
-- field the Principal can see, not silently survive validation and print
-- as a literal brace pair on a board document.
-- lib/certificates/merge.ts carries the identical pattern for the
-- renderer and is unit-tested against these same cases.
create or replace function public.certificate_merge_fields(p_body_html text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct btrim(m[1]) order by btrim(m[1])), '{}'::text[])
    from regexp_matches(coalesce(p_body_html, ''), '\{\{([^{}]*)\}\}', 'g') as m;
$$;

revoke execute on function public.certificate_merge_fields(text) from public, anon;
grant execute on function public.certificate_merge_fields(text) to authenticated;

-- The pre-flight the designer UI shows and activation enforces. Returns
-- the report rather than raising, so a draft can be inspected while it is
-- still wrong.
create or replace function public.validate_certificate_template(p_template_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tpl     public.certificate_template%rowtype;
  v_used    text[];
  v_unknown text[];
  v_missing text[];
begin
  select * into v_tpl from public.certificate_template
   where id = p_template_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tpl.campus_id is not null
     and app.auth_role() not in ('super_admin', 'owner')
     and not (v_tpl.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_used := public.certificate_merge_fields(v_tpl.body_html);

  select coalesce(array_agg(f order by f), '{}'::text[]) into v_unknown
    from unnest(v_used) as f
   where not exists (
     select 1 from public.certificate_type_field_catalog c
      where c.certificate_type = v_tpl.certificate_type and c.field_path = f
   );

  select coalesce(array_agg(c.field_path order by c.field_path), '{}'::text[]) into v_missing
    from public.certificate_type_field_catalog c
   where c.certificate_type = v_tpl.certificate_type
     and c.required
     and not (c.field_path = any(v_used));

  return jsonb_build_object(
    'template_id', v_tpl.id,
    'certificate_type', v_tpl.certificate_type,
    'used_fields', to_jsonb(v_used),
    'unknown_fields', to_jsonb(v_unknown),
    'missing_required_fields', to_jsonb(v_missing),
    'ok', cardinality(v_unknown) = 0 and cardinality(v_missing) = 0
  );
end;
$$;

revoke execute on function public.validate_certificate_template(uuid) from public, anon;
grant execute on function public.validate_certificate_template(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Authoring
-- ═══════════════════════════════════════════════════════════════════════

create or replace function public.create_certificate_template(
  p_certificate_type public.certificate_type,
  p_title text,
  p_body_html text,
  p_board_code text default null,
  p_language public.certificate_language default 'en',
  p_page_size public.certificate_page_size default 'A4',
  p_campus_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_next      int;
  v_id        uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_campus_id is null then
    if v_role not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  else
    if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
    if v_role not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;

  select coalesce(max(version), 0) + 1 into v_next
    from public.certificate_template
   where tenant_id = v_tenant_id
     and campus_id is not distinct from p_campus_id
     and certificate_type = p_certificate_type
     and board_code is not distinct from p_board_code
     and language = p_language;

  insert into public.certificate_template (
    tenant_id, campus_id, certificate_type, board_code, language, version,
    title, body_html, page_size, created_by
  ) values (
    v_tenant_id, p_campus_id, p_certificate_type, p_board_code, p_language, v_next,
    p_title, p_body_html, p_page_size, (select auth.uid())
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.create_certificate_template(
  public.certificate_type, text, text, text, public.certificate_language, public.certificate_page_size, uuid
) from public, anon;
grant execute on function public.create_certificate_template(
  public.certificate_type, text, text, text, public.certificate_language, public.certificate_page_size, uuid
) to authenticated;

-- Returns the id of the row that now HOLDS the edit: the same row when a
-- draft was edited in place, a brand-new draft version when
-- trg_template_version_bump forked an activated one (AC2). The caller
-- never has to know which happened.
create or replace function public.save_certificate_template(
  p_template_id uuid,
  p_title text,
  p_body_html text,
  p_page_size public.certificate_page_size
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tpl    public.certificate_template%rowtype;
  v_role   text := app.auth_role();
  v_result uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_tpl from public.certificate_template
   where id = p_template_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tpl.campus_id is null then
    if v_role not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif v_role not in ('super_admin', 'owner') and not (v_tpl.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.certificate_template
     set title = p_title, body_html = p_body_html, page_size = p_page_size
   where id = p_template_id
  returning id into v_result;

  if v_result is null then
    select id into v_result
      from public.certificate_template
     where tenant_id = v_tpl.tenant_id
       and campus_id is not distinct from v_tpl.campus_id
       and certificate_type = v_tpl.certificate_type
       and board_code is not distinct from v_tpl.board_code
       and language = v_tpl.language
       and status = 'draft'
     order by version desc
     limit 1;
  end if;

  return v_result;
end;
$$;

revoke execute on function public.save_certificate_template(uuid, text, text, public.certificate_page_size) from public, anon;
grant execute on function public.save_certificate_template(uuid, text, text, public.certificate_page_size) to authenticated;

-- AC1. Activation is the gate: it is the only moment a template stops
-- being a private draft and starts binding what a board document says, so
-- it is the only moment the merge fields have to be right.
create or replace function public.activate_certificate_template(p_template_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tpl    public.certificate_template%rowtype;
  v_role   text := app.auth_role();
  v_report jsonb;
begin
  if v_role not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_tpl from public.certificate_template
   where id = p_template_id and tenant_id = app.auth_tenant_id()
   for update;
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tpl.campus_id is null then
    if v_role not in ('super_admin', 'owner') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  elsif v_role not in ('super_admin', 'owner') and not (v_tpl.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if v_tpl.status <> 'draft' then
    raise exception 'TEMPLATE_NOT_DRAFT' using errcode = '55000', detail = format('status=%s', v_tpl.status);
  end if;

  v_report := public.validate_certificate_template(p_template_id);

  if jsonb_array_length(v_report -> 'unknown_fields') > 0 then
    raise exception 'MERGE_FIELD_NOT_ALLOWED'
      using errcode = '23514',
            detail = format('unknown_fields=%s', array_to_string(
              array(select jsonb_array_elements_text(v_report -> 'unknown_fields')), ',')),
            hint = 'Use only merge fields listed in the certificate field catalogue for this certificate type.';
  end if;

  if jsonb_array_length(v_report -> 'missing_required_fields') > 0 then
    raise exception 'MERGE_FIELD_REQUIRED_MISSING'
      using errcode = '23514',
            detail = format('missing_required_fields=%s', array_to_string(
              array(select jsonb_array_elements_text(v_report -> 'missing_required_fields')), ',')),
            hint = 'A document of this type is not accepted without these fields.';
  end if;

  update public.certificate_template
     set status = 'retired'
   where tenant_id = v_tpl.tenant_id
     and campus_id is not distinct from v_tpl.campus_id
     and certificate_type = v_tpl.certificate_type
     and board_code is not distinct from v_tpl.board_code
     and language = v_tpl.language
     and status = 'active';

  update public.certificate_template
     set status = 'active',
         merge_field_whitelist = v_report -> 'used_fields',
         activated_at = clock_timestamp(),
         activated_by = (select auth.uid())
   where id = p_template_id;

  return p_template_id;
end;
$$;

revoke execute on function public.activate_certificate_template(uuid) from public, anon;
grant execute on function public.activate_certificate_template(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Resolution — AC3, and the entry point FR-T03/T05 call
-- ═══════════════════════════════════════════════════════════════════════

-- Most specific active template wins: campus+board, then campus for any
-- board, then the tenant default for that board, then the tenant default
-- for any board. NULL when nothing matches — a caller that cannot issue
-- without a template must say so, not print an English document because
-- the Urdu one is missing.
--
-- Silent NULL (rather than FORBIDDEN) for an out-of-scope campus follows
-- resolve_branding()'s own convention, set in b16ba25.
create or replace function public.resolve_certificate_template(
  p_campus_id uuid,
  p_certificate_type public.certificate_type,
  p_board_code text default null,
  p_language public.certificate_language default 'en'
)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_id        uuid;
begin
  if v_tenant_id is null then
    return null;
  end if;
  if p_campus_id is not null
     and app.auth_role() not in ('super_admin', 'owner')
     and not (p_campus_id = any(app.auth_campus_ids())) then
    return null;
  end if;

  select id into v_id
    from public.certificate_template
   where tenant_id = v_tenant_id
     and certificate_type = p_certificate_type
     and language = p_language
     and status = 'active'
     and (campus_id = p_campus_id or campus_id is null)
     and (board_code = p_board_code or board_code is null)
   order by (campus_id is not null) desc, (board_code is not null) desc
   limit 1;

  return v_id;
end;
$$;

revoke execute on function public.resolve_certificate_template(
  uuid, public.certificate_type, text, public.certificate_language
) from public, anon;
grant execute on function public.resolve_certificate_template(
  uuid, public.certificate_type, text, public.certificate_language
) to authenticated;

-- Everything the preview renderer needs in one read: the template itself,
-- the school/campus identity for the letterhead, the campus-then-tenant
-- letterhead and logo from FR-A18, and a sample value per merge field in
-- the template's own language. FR-T03 will have the real student values
-- to substitute; until then this is what makes a template previewable.
create or replace function public.certificate_preview_payload(p_template_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tpl       public.certificate_template%rowtype;
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
begin
  select * into v_tpl from public.certificate_template
   where id = p_template_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'TEMPLATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_tpl.campus_id is not null
     and app.auth_role() not in ('super_admin', 'owner')
     and not (v_tpl.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- A tenant-default template has no campus of its own; preview it against
  -- whichever campus the viewer is actually scoped to, so the letterhead
  -- is a real one rather than blank.
  v_campus_id := coalesce(
    v_tpl.campus_id,
    (select c.id from public.campus c
      where c.tenant_id = v_tenant_id and c.status = 'active'
        and (app.auth_role() in ('super_admin', 'owner') or c.id = any(app.auth_campus_ids()))
      order by c.code limit 1)
  );

  return jsonb_build_object(
    'template', jsonb_build_object(
      'id', v_tpl.id,
      'certificate_type', v_tpl.certificate_type,
      'board_code', v_tpl.board_code,
      'language', v_tpl.language,
      'version', v_tpl.version,
      'status', v_tpl.status,
      'title', v_tpl.title,
      'body_html', v_tpl.body_html,
      'page_size', v_tpl.page_size
    ),
    'tenant', (select jsonb_build_object('name', t.name, 'name_ur', t.name_ur) from public.tenant t where t.id = v_tenant_id),
    'campus', (select jsonb_build_object('name', c.name, 'name_ur', c.name_ur, 'code', c.code, 'city', c.city)
                 from public.campus c where c.id = v_campus_id),
    'letterhead_storage_path', (public.resolve_branding(v_campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path', (public.resolve_branding(v_campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'sample_values', coalesce((
      select jsonb_object_agg(c.field_path, case when v_tpl.language = 'ur' then coalesce(c.sample_ur, c.sample_en) else c.sample_en end)
        from public.certificate_type_field_catalog c
       where c.certificate_type = v_tpl.certificate_type
    ), '{}'::jsonb)
  );
end;
$$;

revoke execute on function public.certificate_preview_payload(uuid) from public, anon;
grant execute on function public.certificate_preview_payload(uuid) to authenticated;
