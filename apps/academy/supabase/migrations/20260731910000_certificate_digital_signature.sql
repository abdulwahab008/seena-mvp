-- FR-T09: digital signature and stamp on issued PDFs.
--
-- "As a Principal, I want my signature and the school stamp applied to
-- issued certificates automatically with a per-issue cryptographic hash, so
-- that a photocopied forgery can be distinguished from an authentic
-- document."
--
-- Last of module T's certificates cluster. FR-T01 (20260731860000) authored
-- the wording and moved the PDF machinery to lib/pdf/, FR-T02
-- (20260731870000) built the gapless allocator, FR-T03 (20260731880000)
-- created certificate_issue, the private `certificates` bucket and the
-- render-after-commit sequence, FR-T05 (20260731890000) added the second
-- certificate type on that same sequence, and FR-T08 (20260731900000) made
-- the register append-only. Every one of those five headers names
-- pdf_sha256 and signing_identity_id as this FR's; they land here.
--
-- ── The hash cannot be written at INSERT, and what follows from that ────
--
-- FR-T08's header assumed both new columns "are written at INSERT by the
-- issuing transaction, so both simply join the frozen set". Half of that is
-- true and is built that way: signing_identity_id IS known before the row
-- exists, so it is written at INSERT and joins the eighteen frozen columns
-- as a nineteenth. The hash is not. FR-T03's shape is deliberately
-- insert-row-then-render-in-the-server-action — Postgres cannot render a
-- PDF, so the bytes do not exist until after the issuing transaction has
-- committed, and a digest of bytes that do not exist yet cannot be stored
-- with them.
--
-- So pdf_sha256 arrives as the FOURTH named transition FR-T08 said it would
-- have to be if it could not be an INSERT, on exactly the terms that header
-- set: its own frame in the allow-list, never a relaxation of the frozen
-- set.
--
--   D. SEAL — frame public.attach_certificate_pdf_digest(. status stays
--      'issued', revoked_at / revoke_reason / revoked_by /
--      replaced_by_issue_id all unchanged, all nineteen frozen columns
--      byte-identical, and pdf_sha256 goes null -> not null AND NEVER ANY
--      OTHER WAY. Write-once, in the one direction that means anything: a
--      hash that can be rewritten is not a tamper check, it is a second
--      place to forge.
--
-- The other three transitions (VOID, CANCEL, LINK) additionally require
-- pdf_sha256 to be unchanged, so withdrawing a certificate never disturbs
-- the digest of the document that was handed over. The refusal message is
-- still the single string FR-T08 chose, because the property being defended
-- is still one property.
--
-- What the digest can and cannot prove is worth stating plainly. The bytes
-- are hashed in Node, by the same server action that produced and uploaded
-- them, and the hex is handed to attach_certificate_pdf_digest(); Postgres
-- has no access to the storage backend and cannot hash the object itself.
-- The action re-downloads the stored object and hashes THAT, so what is
-- recorded is a digest of what the bucket actually holds rather than of
-- what was sent to it. From that moment the register's copy is immutable
-- (this migration) and the object's bytes are immutable (FR-T03 uploads
-- with upsert:false and the bucket has no UPDATE or DELETE policy), so any
-- later divergence between the two is detectable and is somebody's doing.
--
-- ── AC1: the composite, and what "300 DPI" means in this pipeline ───────
--
-- The house renderer is server-rendered HTML through headless Chromium
-- (FR-F15, generalised by FR-T01), so an anchor is a CSS position and an
-- opacity is an opacity. certificate_template gains the anchor box —
-- signature at (140mm, 235mm) by default, which is the AC's own anchor, the
-- stamp beside it, and stamp_opacity at 0.60 — because the anchor is a
-- property of the printed layout and belongs on the version that layout was
-- frozen into. They are therefore also part of what
-- trg_template_version_bump treats as wording: moving a signature on an
-- ACTIVATED template forks a new draft version exactly as re-writing a
-- paragraph does, and the certificates already issued against v3 keep
-- printing where v3 said.
--
-- "300 DPI" is a statement about the SOURCE image, because nothing
-- downstream can add detail: an image placed in a 45mm-wide box prints at
-- 300 DPI only if it carries at least ceil(45 / 25.4 * 300) = 532 pixels
-- across. That is checked, not assumed, and it is checked twice:
-- create_signing_identity() refuses a signature or stamp asset that is
-- below the floor for the DEFAULT box (so the Owner is told at upload time,
-- when they can still go and rescan it), and lib/certificates/seal.ts
-- re-checks against the ACTUAL template box at render time and voids the
-- issue rather than silently upscaling a blurry signature onto a statutory
-- document. FR-A18 already records width_px/height_px on every
-- branding_asset, so both checks read a real measurement rather than a
-- claimed one.
--
-- "Without obscuring the serial number" is solved by paint order rather
-- than by geometry, and that is a stronger guarantee than the AC asks for:
-- the seal layer is painted BEHIND everything on the page, so no text —
-- the serial included — can be covered by it wherever the anchor is moved
-- to and whatever the template's wording puts near it. A geometric check
-- would have to know where the serial ended up after layout, which only
-- the browser knows; z-order needs no such knowledge and cannot be defeated
-- by a template edit.
--
-- ── AC2: the digest is checked on the way OUT, and a mismatch is an alert ─
--
-- Certificates are no longer handed out as raw signed bucket URLs. Every
-- download goes through app/api/certificates/[issueId]/download, which
-- fetches the object, re-hashes it and compares. Equal: the bytes are
-- served. Not equal: HTTP 409, no bytes, and a security_event row.
--
-- security_event is a NEW table rather than a reuse of FR-T14's audit_log,
-- and the reason is that audit_log is a log of ROW CHANGES — its action is
-- an enum of exactly ('insert','update','delete'), its payload is
-- before/after/changed_columns, and its rows are what
-- run_audit_chain_verification() walks. A download whose bytes did not
-- match changed no row. FR-T08 did file its DELETE denial there, but that
-- was an actual delete attempt against an actual table, so 'delete' was the
-- truth; calling a failed digest check an 'update' would not be. The new
-- table is still chained into audit_log through the ordinary
-- app.tg_audit_row() trigger, so the alert is itself tamper-evident and
-- FR-T14's verification still covers it — the alert row is the evidence and
-- the audit row is the evidence that the alert row was not planted.
--
-- FR-T08's "reject but still record" paradox does not arise here, and it is
-- worth being explicit about why: that one was a BEFORE DELETE trigger,
-- where the RAISE that rejects also rolls back the audit row that records.
-- A 409 is returned from a route handler, not raised from a trigger — the
-- security_event INSERT commits in its own statement and the handler THEN
-- returns the error. Nothing is rolled back and nothing had to be
-- restructured.
--
-- ── AC3: already true, and now recorded ────────────────────────────────
--
-- "Previously issued certificates continue to render the PRIOR signature"
-- holds because an issued certificate is NEVER RE-RENDERED. The PDF is
-- produced once, at issue, uploaded with upsert:false to a bucket with no
-- UPDATE or DELETE policy, and every download since is those same bytes
-- served verbatim — which is also precisely what makes the digest check
-- above meaningful. Replacing the signature image changes what the NEXT
-- issue composites and nothing else; there is no re-render path that could
-- reach back into a stored document. What was genuinely missing is the
-- record of WHO signed: signing_identity_id is stamped on the row at
-- INSERT, a superseded identity keeps its row (it is closed with a valid_to,
-- never deleted — and the FK from certificate_issue would refuse the delete
-- anyway), and v_certificate_register prints the holder and designation
-- beside the entry.
--
-- ── AC4: the branding bucket did NOT already satisfy it ────────────────
--
-- FR-A18's `branding` bucket already holds 'signature' and 'stamp' assets
-- with campus->tenant resolution, and FR-T01 explicitly declined to create
-- a second `cert-assets` bucket for the same four asset kinds. That reuse
-- stands: no `cert-signatures` bucket is created here either, for the same
-- reason FR-T01 gave — a second bucket holding the same kinds under a
-- second set of policies is a duplicate that will drift.
--
-- But FR-A18's own policies do not satisfy AC4 as written, and this was
-- verified rather than assumed: branding_insert_owner admits
-- ('super_admin', 'owner', 'principal'), and create_branding_asset() admits
-- the same three. A Principal uploading a signature is exactly the role the
-- AC names as "other than owner or super_admin". So the gap is closed where
-- it is, in two places:
--
--   * create_branding_asset() now refuses 'signature' and 'stamp' for any
--     role but Owner and Super Admin. Logos and letterheads are untouched —
--     a Principal still runs their own campus's branding.
--   * branding_signature_owner_only is a RESTRICTIVE storage policy, so it
--     ANDs with branding_insert_owner instead of OR-ing into it (a second
--     permissive policy could only ever widen). It is the storage policy
--     the AC asks to be rejected by, it names no bucket but `branding`
--     (every other bucket short-circuits true), and it is what stops a
--     Principal writing bytes to a path an Owner reserved.
--
-- ── Deliberate departures from the FR's suggested objects ──────────────
--
--   * NO `cert-signatures` bucket — see AC4 above.
--   * NO edge functions (render-certificate / verify-certificate-bytes).
--     This repo has no supabase/functions directory; FR-T01 established
--     server actions and route handlers as the equivalent seam and every
--     certificate FR since has used them.
--   * signing_identity stores signature_asset_id / stamp_asset_id rather
--     than the suggested signature_path / stamp_path. The path is one
--     column of a branding_asset row that also carries the pixel dimensions
--     the DPI check needs, the version history AC3 leans on and the storage
--     policies that already guard it; copying just the path out would be a
--     second, unversioned record of the same file.
--
-- Every function below has its full signature fixed. Adding a defaulted
-- argument with CREATE OR REPLACE creates a DISTINCT overload and makes
-- existing calls ambiguous (FR-G05 hit exactly this) — drop and recreate,
-- and re-issue the grants.

-- ═══════════════════════════════════════════════════════════════════════
-- The printed anchor, on the template version it belongs to
-- ═══════════════════════════════════════════════════════════════════════

-- Millimetres from the top-left corner of the PAGE, not of the text block:
-- a signatory points at a spot on the paper. AC1's (140mm, 235mm) is the
-- signature default, so a template authored before this migration prints
-- exactly where the AC says without anyone editing anything.
alter table public.certificate_template
  add column signature_anchor_x_mm numeric(6,2) not null default 140,
  add column signature_anchor_y_mm numeric(6,2) not null default 235,
  add column signature_width_mm    numeric(6,2) not null default 45,
  add column stamp_anchor_x_mm     numeric(6,2) not null default 35,
  add column stamp_anchor_y_mm     numeric(6,2) not null default 232,
  add column stamp_width_mm        numeric(6,2) not null default 35,
  add column stamp_opacity         numeric(3,2) not null default 0.60;

-- A3 is the largest sheet the renderer offers (420mm x 297mm), so 500mm is
-- comfortably beyond any page and still refuses a fat-fingered 1400.
alter table public.certificate_template
  add constraint chk_cert_template_seal_anchor check (
    signature_anchor_x_mm between 0 and 500 and signature_anchor_y_mm between 0 and 500
    and stamp_anchor_x_mm between 0 and 500 and stamp_anchor_y_mm between 0 and 500
    and signature_width_mm between 5 and 200 and stamp_width_mm between 5 and 200
  );

alter table public.certificate_template
  add constraint chk_cert_template_stamp_opacity check (stamp_opacity > 0 and stamp_opacity <= 1);

-- FR-T01's AC2 trigger, re-emitted so the seal layout counts as wording.
-- Moving a signature 20mm down an ACTIVATED template is a change to what
-- the document looks like, and the certificates already issued against that
-- version must keep printing where it said — which is the same argument the
-- trigger already makes for the body text. The forked draft carries the new
-- anchor, so the edit is not lost, only re-versioned.
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
     and new.merge_field_whitelist is not distinct from old.merge_field_whitelist
     and new.signature_anchor_x_mm is not distinct from old.signature_anchor_x_mm
     and new.signature_anchor_y_mm is not distinct from old.signature_anchor_y_mm
     and new.signature_width_mm    is not distinct from old.signature_width_mm
     and new.stamp_anchor_x_mm     is not distinct from old.stamp_anchor_x_mm
     and new.stamp_anchor_y_mm     is not distinct from old.stamp_anchor_y_mm
     and new.stamp_width_mm        is not distinct from old.stamp_width_mm
     and new.stamp_opacity         is not distinct from old.stamp_opacity then
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
    title, body_html, page_size, status, created_by,
    signature_anchor_x_mm, signature_anchor_y_mm, signature_width_mm,
    stamp_anchor_x_mm, stamp_anchor_y_mm, stamp_width_mm, stamp_opacity
  ) values (
    old.tenant_id, old.campus_id, old.certificate_type, old.board_code, old.language, v_next,
    new.title, new.body_html, new.page_size, 'draft', (select auth.uid()),
    new.signature_anchor_x_mm, new.signature_anchor_y_mm, new.signature_width_mm,
    new.stamp_anchor_x_mm, new.stamp_anchor_y_mm, new.stamp_width_mm, new.stamp_opacity
  );

  return null;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1's floor: pixels a millimetre box needs to print at a given DPI
-- ═══════════════════════════════════════════════════════════════════════

-- ceil(mm / 25.4 * dpi). lib/certificates/seal.ts carries the identical
-- arithmetic for the render-time check and is unit-tested against the same
-- cases; this one is what refuses an inadequate image at upload time.
create or replace function app.min_px_for_mm(p_mm numeric, p_dpi int)
returns int
language sql
immutable
set search_path = ''
as $$
  select ceil(p_mm / 25.4 * p_dpi)::int;
$$;

revoke execute on function app.min_px_for_mm(numeric, int) from public, anon;
grant execute on function app.min_px_for_mm(numeric, int) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- signing_identity — who signs, with which image, for which stretch of time
-- ═══════════════════════════════════════════════════════════════════════

create table public.signing_identity (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  holder_name        text not null,
  designation        text not null,
  -- FR-A18's assets, not copies of them: branding_asset carries the pixel
  -- dimensions the DPI check reads, the version chain that keeps a
  -- superseded signature on disk, and the storage policies that guard it.
  signature_asset_id uuid not null references public.branding_asset(id),
  -- A campus may sign without stamping; a stamp with no signature is not a
  -- signing identity, which is why only this one is nullable.
  stamp_asset_id     uuid references public.branding_asset(id),
  valid_from         date not null default current_date,
  -- NULL means "still the one". Set when the holder is replaced; the row
  -- itself is never deleted, because issued certificates point at it.
  valid_to           date,
  created_by         uuid references public.app_user(user_id),
  created_at         timestamptz not null default clock_timestamp(),
  constraint chk_signing_identity_holder check (btrim(holder_name) <> ''),
  constraint chk_signing_identity_designation check (btrim(designation) <> ''),
  constraint chk_signing_identity_validity check (valid_to is null or valid_to >= valid_from)
);

-- The FR's own index: "who signs at this campus right now".
create index idx_signing_identity_active on public.signing_identity (campus_id) where valid_to is null;
create index idx_signing_identity_scope on public.signing_identity (tenant_id, campus_id, valid_from desc);

create trigger signing_identity_audit after insert or update or delete on public.signing_identity
  for each row execute function app.tg_audit_row();

alter table public.signing_identity enable row level security;

-- Everyone who may issue a certificate may see whose signature is going on
-- it, campus-scoped exactly as the register is.
create policy signing_identity_read_campus on public.signing_identity
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal', 'admissions_officer')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- AC4's rule, at the table: a Principal may run their campus's branding and
-- author its templates, but whose signature goes on a statutory document is
-- the Owner's decision.
create policy signing_identity_write_owner on public.signing_identity
  for all to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner'))
  with check (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner'));

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: the same rule at the bucket
-- ═══════════════════════════════════════════════════════════════════════

-- FR-A18's own gate, narrowed for the two asset types that end up on a
-- statutory document. Logo and letterhead are unchanged.
create or replace function public.create_branding_asset(
  p_asset_type public.branding_asset_type, p_width_px int, p_height_px int, p_bytes int, p_mime_type text, p_file_ext text,
  p_campus_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_min_width  int;
  v_version    int;
  v_id         uuid := gen_random_uuid();
  v_path       text;
  v_scope      text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  -- FR-T09 AC4: a signature or a stamp is the school's mark of authenticity,
  -- not branding.
  if p_asset_type in ('signature', 'stamp') and app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN'
      using errcode = '42501',
            detail = format('asset_type=%s role=%s', p_asset_type, app.auth_role()),
            hint = 'Only an Owner or Super Admin may upload a signature or a school stamp.';
  end if;
  if p_campus_id is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_mime_type not in ('image/jpeg', 'image/png') then
    raise exception 'UNSUPPORTED_FILE_TYPE' using errcode = '22023';
  end if;
  if p_bytes > 3145728 then
    raise exception 'ASSET_TOO_LARGE' using errcode = '23514', detail = 'max_bytes=3145728';
  end if;

  v_min_width := case p_asset_type when 'logo' then 600 when 'letterhead' then 1000 else 200 end;
  if p_width_px < v_min_width then
    raise exception 'ASSET_RESOLUTION_TOO_LOW' using errcode = '23514', detail = format('min_width_px=%s', v_min_width);
  end if;

  select coalesce(max(version), 0) + 1 into v_version
    from public.branding_asset
   where tenant_id = v_tenant_id and campus_id is not distinct from p_campus_id and asset_type = p_asset_type;

  v_scope := coalesce(p_campus_id::text, 'tenant');
  v_path := v_tenant_id::text || '/' || v_scope || '/' || p_asset_type::text || '/' || v_version::text || '.' || p_file_ext;

  insert into public.branding_asset (id, tenant_id, campus_id, asset_type, storage_path, width_px, height_px, bytes, version, uploaded_by)
  values (v_id, v_tenant_id, p_campus_id, p_asset_type, v_path, p_width_px, p_height_px, p_bytes, v_version, auth.uid());

  return jsonb_build_object('asset_id', v_id, 'storage_path', v_path);
end;
$$;

revoke execute on function public.create_branding_asset(public.branding_asset_type, int, int, int, text, text, uuid) from public, anon;
grant execute on function public.create_branding_asset(public.branding_asset_type, int, int, int, text, text, uuid) to authenticated;

-- RESTRICTIVE, so it ANDs with FR-A18's branding_insert_owner rather than
-- OR-ing into it: a second permissive policy could only ever widen who may
-- write. Every bucket but `branding` short-circuits true, and inside
-- `branding` only a path reserved for a signature or a stamp is narrowed —
-- so a Principal uploading a logo is unaffected, and a Principal uploading
-- bytes to a signature path an Owner reserved is refused by the policy
-- itself, which is what AC4 asks for.
create policy branding_signature_owner_only on storage.objects
  as restrictive
  for insert to authenticated
  with check (
    bucket_id <> 'branding'
    or app.auth_role() in ('super_admin', 'owner')
    or not exists (
      select 1 from public.branding_asset ba
       where ba.storage_path = objects.name
         and ba.asset_type in ('signature', 'stamp')
    )
  );

-- ═══════════════════════════════════════════════════════════════════════
-- Managing the signing identity
-- ═══════════════════════════════════════════════════════════════════════

-- The floor a signature/stamp image must clear to print at 300 DPI in the
-- DEFAULT anchor box. The render checks the ACTUAL template's box as well
-- (lib/certificates/seal.ts) — this one exists so an Owner is told at
-- upload time, while they can still rescan, rather than at issue time.
create or replace function public.create_signing_identity(
  p_campus_id uuid,
  p_holder_name text,
  p_designation text,
  p_signature_asset_id uuid,
  p_stamp_asset_id uuid default null,
  p_valid_from date default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_from      date := coalesce(p_valid_from, current_date);
  v_sig       public.branding_asset%rowtype;
  v_stamp     public.branding_asset%rowtype;
  v_min_sig   int := app.min_px_for_mm(45, 300);
  v_min_stamp int := app.min_px_for_mm(35, 300);
  v_id        uuid;
begin
  if v_role not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN'
      using errcode = '42501',
            hint = 'Only an Owner or Super Admin may set who signs a certificate.';
  end if;

  if coalesce(btrim(p_holder_name), '') = '' or coalesce(btrim(p_designation), '') = '' then
    raise exception 'SIGNATORY_INCOMPLETE'
      using errcode = '23514',
            hint = 'A signing identity needs both a name and a designation — they are printed on the document.';
  end if;

  -- SECURITY DEFINER bypasses RLS, so the tenant predicate is written out
  -- (b16ba25's convention).
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_sig from public.branding_asset
   where id = p_signature_asset_id and tenant_id = v_tenant_id;
  if not found or v_sig.asset_type <> 'signature' then
    raise exception 'SIGNATURE_ASSET_NOT_FOUND'
      using errcode = 'P0002',
            detail = format('signature_asset_id=%s', p_signature_asset_id),
            hint = 'Upload the signature image first; it must be a branding asset of type signature.';
  end if;
  if v_sig.width_px < v_min_sig then
    raise exception 'SIGNATURE_RESOLUTION_TOO_LOW'
      using errcode = '23514',
            detail = format('width_px=%s min_width_px=%s box_mm=45 dpi=300', v_sig.width_px, v_min_sig),
            hint = 'A signature printed 45mm wide needs at least 532 pixels across to reach 300 DPI. Rescan it larger.';
  end if;

  if p_stamp_asset_id is not null then
    select * into v_stamp from public.branding_asset
     where id = p_stamp_asset_id and tenant_id = v_tenant_id;
    if not found or v_stamp.asset_type <> 'stamp' then
      raise exception 'STAMP_ASSET_NOT_FOUND'
        using errcode = 'P0002',
              detail = format('stamp_asset_id=%s', p_stamp_asset_id),
              hint = 'The stamp must be a branding asset of type stamp.';
    end if;
    if v_stamp.width_px < v_min_stamp then
      raise exception 'STAMP_RESOLUTION_TOO_LOW'
        using errcode = '23514',
              detail = format('width_px=%s min_width_px=%s box_mm=35 dpi=300', v_stamp.width_px, v_min_stamp),
              hint = 'A stamp printed 35mm wide needs at least 414 pixels across to reach 300 DPI.';
    end if;
  end if;

  -- AC3's replacement, from the other end: the outgoing holder's identity is
  -- CLOSED, not deleted, so every certificate that names it still resolves.
  -- greatest() keeps a same-day handover legal against
  -- chk_signing_identity_validity — the outgoing row's last day is its own
  -- first day, and resolution prefers the later valid_from.
  update public.signing_identity
     set valid_to = greatest(v_from - 1, valid_from)
   where tenant_id = v_tenant_id
     and campus_id = p_campus_id
     and valid_to is null;

  insert into public.signing_identity (
    tenant_id, campus_id, holder_name, designation,
    signature_asset_id, stamp_asset_id, valid_from, created_by
  ) values (
    v_tenant_id, p_campus_id, btrim(p_holder_name), btrim(p_designation),
    p_signature_asset_id, p_stamp_asset_id, v_from, (select auth.uid())
  )
  returning id into v_id;

  return jsonb_build_object(
    'signing_identity_id', v_id,
    'campus_id',           p_campus_id,
    'holder_name',         btrim(p_holder_name),
    'designation',         btrim(p_designation),
    'valid_from',          v_from
  );
end;
$$;

revoke execute on function public.create_signing_identity(uuid, text, text, uuid, uuid, date) from public, anon;
grant execute on function public.create_signing_identity(uuid, text, text, uuid, uuid, date) to authenticated;

-- Closing an identity with no replacement lined up — a Principal who has
-- left. From the day after valid_to, issuance falls back to naming the
-- issuing user, exactly as it did before this FR.
create or replace function public.retire_signing_identity(p_identity_id uuid, p_valid_to date default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_row       public.signing_identity%rowtype;
  v_to        date := coalesce(p_valid_to, current_date);
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_row from public.signing_identity
   where id = p_identity_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'SIGNING_IDENTITY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_row.valid_to is not null then
    raise exception 'SIGNING_IDENTITY_ALREADY_RETIRED'
      using errcode = '55000', detail = format('valid_to=%s', v_row.valid_to);
  end if;

  update public.signing_identity
     set valid_to = greatest(v_to, v_row.valid_from)
   where id = p_identity_id;

  return jsonb_build_object('signing_identity_id', p_identity_id, 'valid_to', greatest(v_to, v_row.valid_from));
end;
$$;

revoke execute on function public.retire_signing_identity(uuid, date) from public, anon;
grant execute on function public.retire_signing_identity(uuid, date) to authenticated;

-- Who signs at this campus TODAY, with everything the renderer needs to
-- place and size the images. NULL when nobody does — a campus with no
-- signing identity still issues certificates, naming the issuing user as
-- FR-T03 and FR-T05 have done all along; it simply composites no images.
--
-- Silent NULL (rather than FORBIDDEN) for an out-of-scope campus follows
-- resolve_branding()'s convention, set in b16ba25.
create or replace function public.resolve_signing_identity(p_campus_id uuid)
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
  if v_tenant_id is null or p_campus_id is null then
    return null;
  end if;
  if app.auth_role() not in ('super_admin', 'owner')
     and not (p_campus_id = any(app.auth_campus_ids())) then
    return null;
  end if;

  select si.id, si.holder_name, si.designation, si.valid_from, si.valid_to,
         sig.storage_path as signature_storage_path,
         sig.width_px     as signature_width_px,
         sig.height_px    as signature_height_px,
         stm.storage_path as stamp_storage_path,
         stm.width_px     as stamp_width_px,
         stm.height_px    as stamp_height_px
    into v_row
    from public.signing_identity si
    join public.branding_asset sig on sig.id = si.signature_asset_id
    left join public.branding_asset stm on stm.id = si.stamp_asset_id
   where si.tenant_id = v_tenant_id
     and si.campus_id = p_campus_id
     and si.valid_from <= current_date
     and (si.valid_to is null or si.valid_to >= current_date)
   order by si.valid_from desc, si.created_at desc
   limit 1;
  if not found then
    return null;
  end if;

  return jsonb_build_object(
    'signing_identity_id',    v_row.id,
    'holder_name',            v_row.holder_name,
    'designation',            v_row.designation,
    'valid_from',             v_row.valid_from,
    'valid_to',               v_row.valid_to,
    'signature_storage_path', v_row.signature_storage_path,
    'signature_width_px',     v_row.signature_width_px,
    'signature_height_px',    v_row.signature_height_px,
    'stamp_storage_path',     v_row.stamp_storage_path,
    'stamp_width_px',         v_row.stamp_width_px,
    'stamp_height_px',        v_row.stamp_height_px
  );
end;
$$;

revoke execute on function public.resolve_signing_identity(uuid) from public, anon;
grant execute on function public.resolve_signing_identity(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- certificate_issue: who signed it, and what its bytes hash to
-- ═══════════════════════════════════════════════════════════════════════

-- Written at INSERT, and frozen from that moment — it joins FR-T08's frozen
-- set as a nineteenth column.
alter table public.certificate_issue
  add column signing_identity_id uuid references public.signing_identity(id);

-- Lower-case hex sha-256 of the stored PDF's bytes. NULL until the render
-- has produced and stored them; write-once thereafter.
alter table public.certificate_issue
  add column pdf_sha256 text;

alter table public.certificate_issue
  add constraint chk_cert_issue_pdf_sha256 check (pdf_sha256 is null or pdf_sha256 ~ '^[0-9a-f]{64}$');

create index idx_cert_issue_signing_identity on public.certificate_issue (signing_identity_id)
  where signing_identity_id is not null;

-- FR-T08's append-only trigger, re-emitted with the nineteenth frozen
-- column and the fourth transition. Everything else is verbatim: the same
-- owner check, the same three transitions, the same single refusal message.
create or replace function app.tg_cert_issue_no_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_stack text;
  v_owner text;
  v_frozen boolean;
  v_hash_frozen boolean;
begin
  select pg_catalog.pg_get_userbyid(c.relowner) into v_owner
    from pg_catalog.pg_class c
   where c.oid = tg_relid;

  get diagnostics v_stack = pg_context;

  -- Nineteen columns that no sanctioned transition may touch. Checked once
  -- rather than repeated per transition, so a column added later is frozen
  -- by default and has to be argued out of this list rather than into it.
  v_frozen :=
        new.id                  is not distinct from old.id
    and new.tenant_id           is not distinct from old.tenant_id
    and new.campus_id           is not distinct from old.campus_id
    and new.student_id          is not distinct from old.student_id
    and new.enrolment_id        is not distinct from old.enrolment_id
    and new.session_id          is not distinct from old.session_id
    and new.certificate_type    is not distinct from old.certificate_type
    and new.serial_no           is not distinct from old.serial_no
    and new.serial_seq          is not distinct from old.serial_seq
    and new.template_id         is not distinct from old.template_id
    and new.template_version    is not distinct from old.template_version
    and new.language            is not distinct from old.language
    and new.pdf_path            is not distinct from old.pdf_path
    and new.payload_snapshot    is not distinct from old.payload_snapshot
    and new.issued_by           is not distinct from old.issued_by
    and new.issued_at           is not distinct from old.issued_at
    and new.original_issue_id   is not distinct from old.original_issue_id
    and new.created_at          is not distinct from old.created_at
    -- FR-T09. Who signed a document is as frozen as what it says.
    and new.signing_identity_id is not distinct from old.signing_identity_id;

  -- FR-T09. The digest moves in exactly one transition, and only from NULL.
  v_hash_frozen := new.pdf_sha256 is not distinct from old.pdf_sha256;

  if current_user = v_owner and v_frozen then
    -- A. FR-T03's void: the document never came into existence.
    if v_stack ~ 'function public\.void_certificate_issue\('
       and v_hash_frozen
       and old.status = 'issued' and new.status = 'void'
       and old.revoked_at is null and new.revoked_at is not null
       and new.replaced_by_issue_id is not distinct from old.replaced_by_issue_id
    then
      return new;
    end if;

    -- B. The strike-through itself.
    if v_stack ~ 'function public\.revoke_certificate\('
       and v_hash_frozen
       and old.status = 'issued' and new.status = 'cancelled'
       and old.revoked_at is null and new.revoked_at is not null
       and new.revoke_reason is not null
       and old.replaced_by_issue_id is null
    then
      return new;
    end if;

    -- C. The cross-reference, written once, in one direction, after the
    -- replacement exists.
    if v_stack ~ 'function public\.set_certificate_replacement\('
       and v_hash_frozen
       and old.status = 'cancelled' and new.status = 'cancelled'
       and new.revoked_at    is not distinct from old.revoked_at
       and new.revoke_reason is not distinct from old.revoke_reason
       and new.revoked_by    is not distinct from old.revoked_by
       and old.replaced_by_issue_id is null
       and new.replaced_by_issue_id is not null
    then
      return new;
    end if;

    -- D. FR-T09's seal: the digest of the bytes that were just stored,
    -- written once, never rewritten, never cleared. Nothing else about the
    -- entry moves with it.
    if v_stack ~ 'function public\.attach_certificate_pdf_digest\('
       and old.pdf_sha256 is null and new.pdf_sha256 is not null
       and old.status = 'issued' and new.status = 'issued'
       and new.revoked_at           is not distinct from old.revoked_at
       and new.revoke_reason        is not distinct from old.revoke_reason
       and new.revoked_by           is not distinct from old.revoked_by
       and new.replaced_by_issue_id is not distinct from old.replaced_by_issue_id
    then
      return new;
    end if;
  end if;

  raise exception 'certificate register is append-only'
    using errcode = '42501',
          detail = format('update of certificate_issue id=%s serial_no=%s status=%s->%s by %s',
                          old.id, old.serial_no, old.status, new.status, current_user),
          hint = 'A register entry is written once. Withdraw it with revoke_certificate() and issue a replacement; the entry keeps its serial and stays in sequence.';
end;
$$;

-- The only writer of pdf_sha256 there is. Called by the issuing action once
-- the object is in the bucket and its stored bytes have been hashed.
create or replace function public.attach_certificate_pdf_digest(p_issue_id uuid, p_sha256 text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_issue     public.certificate_issue%rowtype;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'DIGEST_MALFORMED'
      using errcode = '22023',
            hint = 'A sha-256 digest is 64 lower-case hex characters.';
  end if;

  -- SECURITY DEFINER bypasses RLS, so the tenant predicate is written out
  -- and the campus scope is checked explicitly (b16ba25's convention).
  select * into v_issue from public.certificate_issue
   where id = p_issue_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'CERTIFICATE_ISSUE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_issue.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_issue.status <> 'issued' then
    raise exception 'CERTIFICATE_NOT_ISSUED'
      using errcode = '55000', detail = format('status=%s', v_issue.status);
  end if;
  if v_issue.pdf_sha256 is not null then
    raise exception 'CERTIFICATE_ALREADY_SEALED'
      using errcode = '23505',
            detail = format('pdf_sha256=%s', v_issue.pdf_sha256),
            hint = 'A certificate is sealed once — its digest is the record of the bytes that were issued.';
  end if;

  update public.certificate_issue set pdf_sha256 = p_sha256 where id = p_issue_id;

  return jsonb_build_object('issue_id', p_issue_id, 'serial_no', v_issue.serial_no, 'pdf_sha256', p_sha256);
end;
$$;

revoke execute on function public.attach_certificate_pdf_digest(uuid, text) from public, anon;
grant execute on function public.attach_certificate_pdf_digest(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the alert a failed digest check leaves behind
-- ═══════════════════════════════════════════════════════════════════════

create table public.security_event (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid references public.campus(id) on delete cascade,
  event_type    text not null,
  severity      text not null default 'alert',
  -- What the event is ABOUT, as table + row, so an alert can be joined back
  -- to the thing it concerns without a column per subject kind.
  subject_table text,
  subject_id    uuid,
  actor_user_id uuid references public.app_user(user_id),
  detail        jsonb not null default '{}'::jsonb,
  occurred_at   timestamptz not null default clock_timestamp(),
  constraint chk_security_event_severity check (severity in ('info', 'warning', 'alert')),
  constraint chk_security_event_detail check (jsonb_typeof(detail) = 'object')
);

create index idx_security_event_scope on public.security_event (tenant_id, occurred_at desc);
create index idx_security_event_subject on public.security_event (subject_table, subject_id);

-- The alert is itself tamper-evident: FR-T14's chain covers it like every
-- other table, so a planted or deleted alert row is visible to
-- run_audit_chain_verification().
create trigger security_event_audit after insert or update or delete on public.security_event
  for each row execute function app.tg_audit_row();

alter table public.security_event enable row level security;

-- Read by the people who would act on it. No INSERT, UPDATE or DELETE
-- policy at all: the only writer is the SECURITY DEFINER function below,
-- which runs as the table owner and is not subject to RLS.
create policy security_event_read_admin on public.security_event
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and (app.auth_role() in ('super_admin', 'owner') or campus_id is null or campus_id = any(app.auth_campus_ids()))
  );

-- Granted to authenticated on purpose, and that is a considered decision:
-- the download path runs as whoever is downloading, and a GUARDIAN
-- downloading their child's tampered certificate must raise the same alarm
-- as a clerk. The caller cannot choose what the row says — the event type,
-- the severity, the subject and the recorded expected digest all come from
-- the issue row this function reads for itself — and cannot write an alert
-- about a certificate they may not read. Observed digest and byte count are
-- the caller's claim and are recorded as such.
create or replace function public.log_certificate_digest_mismatch(
  p_issue_id uuid,
  p_observed_sha256 text,
  p_observed_bytes bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_issue     public.certificate_issue%rowtype;
  v_id        uuid;
begin
  if v_tenant_id is null then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_issue from public.certificate_issue
   where id = p_issue_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'CERTIFICATE_ISSUE_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- The same visibility certificate_issue's own SELECT policies grant:
  -- campus-scoped staff, or the guardian of the student it belongs to.
  if not (
    (v_role in ('super_admin', 'owner', 'principal', 'admissions_officer')
     and (v_role in ('super_admin', 'owner') or v_issue.campus_id = any(app.auth_campus_ids())))
    or v_issue.student_id = any(app.auth_guardian_student_ids())
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.security_event (
    tenant_id, campus_id, event_type, severity, subject_table, subject_id, actor_user_id, detail
  ) values (
    v_issue.tenant_id, v_issue.campus_id, 'certificate_digest_mismatch', 'alert',
    'certificate_issue', v_issue.id, (select auth.uid()),
    jsonb_build_object(
      'serial_no',        v_issue.serial_no,
      'certificate_type', v_issue.certificate_type,
      'pdf_path',         v_issue.pdf_path,
      'expected_sha256',  v_issue.pdf_sha256,
      'observed_sha256',  p_observed_sha256,
      'observed_bytes',   p_observed_bytes
    )
  )
  returning id into v_id;

  return jsonb_build_object('security_event_id', v_id, 'serial_no', v_issue.serial_no);
end;
$$;

revoke execute on function public.log_certificate_digest_mismatch(uuid, text, bigint) from public, anon;
grant execute on function public.log_certificate_digest_mismatch(uuid, text, bigint) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- Issuance, re-emitted: the identity is resolved and stamped at INSERT
-- ═══════════════════════════════════════════════════════════════════════

-- Identical to 20260731880000's definition except that it resolves the
-- campus's signing identity, prints ITS name and designation rather than
-- the issuing user's, freezes the seal (images, anchors, opacity) into the
-- snapshot the renderer works from, and records signing_identity_id on the
-- row. A campus with no signing identity is unchanged in every respect —
-- the fallback to the issuing user's name is FR-T03's own and stays.
create or replace function public.issue_transfer_certificate(
  p_enrolment_id uuid,
  p_leaving_date date,
  p_reason text default null,
  p_conduct text default null,
  p_board_code text default null,
  p_language public.certificate_language default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_uid         uuid := (select auth.uid());
  v_e           record;
  v_existing    record;
  v_template    public.certificate_template%rowtype;
  v_template_id uuid;
  v_signatory   text;
  v_identity    jsonb;
  v_identity_id uuid;
  v_seal        jsonb;
  v_issued_on   date := current_date;
  v_values      jsonb;
  v_snapshot    jsonb;
  v_serial      text;
  v_pdf_path    text;
  v_issue_id    uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select e.tenant_id, e.campus_id, e.session_id, e.student_id,
         e.status::text as enrolment_status, e.joined_on, e.deleted_at,
         s.name_en, s.name_ur, s.father_name_en, s.father_name_ur, s.gr_number,
         s.dob, s.gender::text as gender, s.religion, s.b_form_no,
         s.deleted_at as student_deleted_at,
         cl.name_en as class_name,
         cs.name as section_name,
         sess.name as session_name,
         c.name as campus_name, c.name_ur as campus_name_ur, c.code as campus_code, c.city as campus_city,
         t.name as tenant_name, t.name_ur as tenant_name_ur
    into v_e
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
    join public.academic_session sess on sess.id = e.session_id
    join public.campus c on c.id = e.campus_id
    join public.tenant t on t.id = e.tenant_id
   where e.id = p_enrolment_id
     and e.tenant_id = v_tenant_id
   for update of e;

  if not found or v_e.deleted_at is not null or v_e.student_deleted_at is not null then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_role not in ('super_admin', 'owner') and not (v_e.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select ci.id, ci.serial_no, ci.issued_at
    into v_existing
    from public.certificate_issue ci
   where ci.enrolment_id = p_enrolment_id
     and ci.certificate_type = 'transfer'
     and ci.status = 'issued'
   limit 1;
  if found then
    raise exception 'TC_ALREADY_ISSUED: %', v_existing.serial_no
      using errcode = '23505',
            detail = format('issue_id=%s serial_no=%s issued_at=%s',
                            v_existing.id, v_existing.serial_no, v_existing.issued_at),
            hint = 'Use Duplicate instead of issuing a second original.';
  end if;

  if v_e.enrolment_status <> 'active' then
    raise exception 'ENROLMENT_NOT_ACTIVE'
      using errcode = '55000',
            detail = format('enrolment_status=%s', v_e.enrolment_status),
            hint = 'A Transfer Certificate can only be issued for a student who is actually enrolled.';
  end if;

  if p_leaving_date is null or p_leaving_date < v_e.joined_on then
    raise exception 'LEAVING_DATE_BEFORE_ADMISSION'
      using errcode = '23514',
            detail = format('leaving_date=%s joined_on=%s', p_leaving_date, v_e.joined_on),
            hint = 'The leaving date cannot precede the date of admission.';
  end if;

  v_template_id := public.resolve_certificate_template(
    v_e.campus_id, 'transfer'::public.certificate_type, p_board_code, p_language);
  if v_template_id is null then
    raise exception 'TEMPLATE_NOT_FOUND'
      using errcode = 'P0002',
            detail = format('campus_id=%s board_code=%s language=%s', v_e.campus_id, p_board_code, p_language),
            hint = 'Activate a Transfer Certificate template for this campus, board and language first.';
  end if;
  select * into v_template from public.certificate_template where id = v_template_id;

  select au.full_name into v_signatory
    from public.app_user au where au.user_id = v_uid;

  -- FR-T09. NULL when the campus has none, and then everything below reads
  -- exactly as it did before this FR.
  v_identity := public.resolve_signing_identity(v_e.campus_id);
  v_identity_id := (v_identity ->> 'signing_identity_id')::uuid;

  v_values := jsonb_build_object(
    'school.name_en',              v_e.tenant_name,
    'school.name_ur',              v_e.tenant_name_ur,
    'campus.name',                 v_e.campus_name,
    'campus.code',                 v_e.campus_code,
    'issue.date',                  to_char(v_issued_on, 'DD-MM-YYYY'),
    'issue.place',                 v_e.campus_city,
    'student.name_en',             v_e.name_en,
    'student.name_ur',             v_e.name_ur,
    'student.father_name_en',      v_e.father_name_en,
    'student.father_name_ur',      v_e.father_name_ur,
    'student.gr_number',           v_e.gr_number,
    'student.dob',                 to_char(v_e.dob, 'DD-MM-YYYY'),
    'student.dob_words',           public.dob_to_words(v_e.dob, v_template.language::text),
    'student.gender',              initcap(v_e.gender),
    'student.religion',            v_e.religion,
    'student.b_form_no',           v_e.b_form_no,
    'enrolment.class_name',        v_e.class_name,
    'enrolment.section_name',      v_e.section_name,
    'enrolment.session_name',      v_e.session_name,
    'enrolment.joined_on',         to_char(v_e.joined_on, 'DD-MM-YYYY'),
    'enrolment.left_on',           to_char(p_leaving_date, 'DD-MM-YYYY'),
    'transfer.reason',             p_reason,
    'transfer.last_class_studied', v_e.class_name,
    'transfer.conduct',            p_conduct,
    'transfer.dues_cleared',       null,
    'transfer.remarks',            null,
    -- FR-T09: the signing identity is what the document is signed by; the
    -- issuing user remains the fallback where no identity is set.
    'signatory.name',              coalesce(v_identity ->> 'holder_name', nullif(v_signatory, '')),
    'signatory.designation',       coalesce(v_identity ->> 'designation', initcap(replace(v_role, '_', ' ')))
  );

  v_serial := public.allocate_certificate_serial(
    v_e.campus_id, 'transfer'::public.certificate_type, v_e.session_id);
  v_values := v_values || jsonb_build_object('issue.serial_no', v_serial);

  v_pdf_path := v_e.tenant_id::text || '/' || v_e.campus_id::text || '/transfer/'
                || replace(v_serial, '/', '-') || '.pdf';

  v_seal := case when v_identity is null then null else
    v_identity || jsonb_build_object(
      'signature_anchor_x_mm', v_template.signature_anchor_x_mm::float8,
      'signature_anchor_y_mm', v_template.signature_anchor_y_mm::float8,
      'signature_width_mm',    v_template.signature_width_mm::float8,
      'stamp_anchor_x_mm',     v_template.stamp_anchor_x_mm::float8,
      'stamp_anchor_y_mm',     v_template.stamp_anchor_y_mm::float8,
      'stamp_width_mm',        v_template.stamp_width_mm::float8,
      'stamp_opacity',         v_template.stamp_opacity::float8
    )
  end;

  v_snapshot := jsonb_build_object(
    'template', jsonb_build_object(
      'id',               v_template.id,
      'certificate_type', v_template.certificate_type,
      'board_code',       v_template.board_code,
      'language',         v_template.language,
      'version',          v_template.version,
      'status',           'issued',
      'title',            v_template.title,
      'body_html',        v_template.body_html,
      'page_size',        v_template.page_size
    ),
    'tenant', jsonb_build_object('name', v_e.tenant_name, 'name_ur', v_e.tenant_name_ur),
    'campus', jsonb_build_object('name', v_e.campus_name, 'name_ur', v_e.campus_name_ur,
                                 'code', v_e.campus_code, 'city', v_e.campus_city),
    'letterhead_storage_path',
      (public.resolve_branding(v_e.campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path',
      (public.resolve_branding(v_e.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'seal', v_seal,
    'values', v_values
  );

  insert into public.certificate_issue (
    tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
    serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_by,
    signing_identity_id
  ) values (
    v_e.tenant_id, v_e.campus_id, v_e.student_id, p_enrolment_id, v_e.session_id, 'transfer',
    v_serial, v_template.id, v_template.version, v_template.language, v_pdf_path, v_snapshot, v_uid,
    v_identity_id
  )
  returning id into v_issue_id;

  update public.enrolment
     set status = 'transferred',
         left_on = p_leaving_date,
         tc_issued_at = clock_timestamp(),
         tc_certificate_issue_id = v_issue_id
   where id = p_enrolment_id;

  return jsonb_build_object(
    'issue_id',            v_issue_id,
    'serial_no',           v_serial,
    'pdf_path',            v_pdf_path,
    'certificate_type',    'transfer',
    'status',              'issued',
    'template_id',         v_template.id,
    'template_version',    v_template.version,
    'language',            v_template.language,
    'signing_identity_id', v_identity_id,
    'payload_snapshot',    v_snapshot
  );
end;
$$;

revoke execute on function public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language
) from public, anon;
grant execute on function public.issue_transfer_certificate(
  uuid, date, text, text, text, public.certificate_language
) to authenticated;

-- Identical to 20260731890000's definition, with the same three FR-T09
-- additions and nothing else.
create or replace function public.issue_character_certificate(
  p_student_id uuid,
  p_conduct text,
  p_period_from date default null,
  p_period_to date default null,
  p_remarks text default null,
  p_board_code text default null,
  p_language public.certificate_language default 'en'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id   uuid := app.auth_tenant_id();
  v_role        text := app.auth_role();
  v_uid         uuid := (select auth.uid());
  v_s           record;
  v_e           record;
  v_session     record;
  v_span        jsonb;
  v_from        date;
  v_to          date;
  v_template    public.certificate_template%rowtype;
  v_template_id uuid;
  v_signatory   text;
  v_identity    jsonb;
  v_identity_id uuid;
  v_seal        jsonb;
  v_issued_on   date := current_date;
  v_values      jsonb;
  v_snapshot    jsonb;
  v_serial      text;
  v_pdf_path    text;
  v_issue_id    uuid;
begin
  if v_role not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select s.tenant_id, s.campus_id, s.deleted_at,
         s.name_en, s.name_ur, s.father_name_en, s.father_name_ur, s.gr_number,
         s.dob, s.gender::text as gender, s.religion, s.b_form_no,
         c.name as campus_name, c.name_ur as campus_name_ur, c.code as campus_code, c.city as campus_city,
         t.name as tenant_name, t.name_ur as tenant_name_ur
    into v_s
    from public.student s
    join public.campus c on c.id = s.campus_id
    join public.tenant t on t.id = s.tenant_id
   where s.id = p_student_id
     and s.tenant_id = v_tenant_id;

  if not found or v_s.deleted_at is not null then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_role not in ('super_admin', 'owner') and not (v_s.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if coalesce(p_conduct, '') not in ('Excellent', 'Very Good', 'Good', 'Satisfactory') then
    raise exception 'CONDUCT_GRADE_INVALID'
      using errcode = '23514',
            detail = format('conduct=%s permitted=Excellent,Very Good,Good,Satisfactory', coalesce(p_conduct, '(null)')),
            hint = 'Conduct must be one of Excellent, Very Good, Good or Satisfactory.';
  end if;

  v_span := public.student_attendance_span(p_student_id);
  v_from := coalesce(p_period_from, (v_span ->> 'period_from')::date);
  v_to   := coalesce(p_period_to,   (v_span ->> 'period_to')::date);

  if v_from is null or v_to is null then
    raise exception 'ATTENDANCE_PERIOD_UNKNOWN'
      using errcode = 'P0002',
            detail = format('student_id=%s enrolment_count=%s', p_student_id, v_span ->> 'enrolment_count'),
            hint = 'This student has no enrolment history to derive the period from; state it explicitly.';
  end if;
  if v_to < v_from then
    raise exception 'PERIOD_END_BEFORE_START'
      using errcode = '23514',
            detail = format('period_from=%s period_to=%s', v_from, v_to),
            hint = 'The end of the attendance period cannot precede its start.';
  end if;
  if v_to > v_issued_on then
    raise exception 'PERIOD_IN_FUTURE'
      using errcode = '23514',
            detail = format('period_to=%s today=%s', v_to, v_issued_on),
            hint = 'A certificate cannot certify conduct that has not happened yet.';
  end if;

  select e.id, e.deleted_at,
         cl.name_en as class_name,
         cs.name as section_name,
         sess.name as session_name
    into v_e
    from public.enrolment e
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
    join public.academic_session sess on sess.id = e.session_id
   where e.student_id = p_student_id
     and e.deleted_at is null
   order by e.joined_on desc, sess.starts_on desc
   limit 1;

  select s.id, s.name
    into v_session
    from public.academic_session s
   where s.tenant_id = v_tenant_id
     and s.is_current
     and (s.campus_id = v_s.campus_id or s.campus_id is null)
   order by (s.campus_id is not null) desc
   limit 1;
  if not found then
    raise exception 'ACADEMIC_SESSION_NOT_FOUND'
      using errcode = 'P0002',
            hint = 'A certificate serial belongs to an academic session; the campus has no current one.';
  end if;

  v_template_id := public.resolve_certificate_template(
    v_s.campus_id, 'character'::public.certificate_type, p_board_code, p_language);
  if v_template_id is null then
    raise exception 'TEMPLATE_NOT_FOUND'
      using errcode = 'P0002',
            detail = format('campus_id=%s board_code=%s language=%s', v_s.campus_id, p_board_code, p_language),
            hint = 'Activate a Character Certificate template for this campus, board and language first.';
  end if;
  select * into v_template from public.certificate_template where id = v_template_id;

  select au.full_name into v_signatory
    from public.app_user au where au.user_id = v_uid;

  v_identity := public.resolve_signing_identity(v_s.campus_id);
  v_identity_id := (v_identity ->> 'signing_identity_id')::uuid;

  v_values := jsonb_build_object(
    'school.name_en',            v_s.tenant_name,
    'school.name_ur',            v_s.tenant_name_ur,
    'campus.name',               v_s.campus_name,
    'campus.code',               v_s.campus_code,
    'issue.date',                to_char(v_issued_on, 'DD-MM-YYYY'),
    'issue.place',               v_s.campus_city,
    'student.name_en',           v_s.name_en,
    'student.name_ur',           v_s.name_ur,
    'student.father_name_en',    v_s.father_name_en,
    'student.father_name_ur',    v_s.father_name_ur,
    'student.gr_number',         v_s.gr_number,
    'student.dob',               to_char(v_s.dob, 'DD-MM-YYYY'),
    'student.dob_words',         public.dob_to_words(v_s.dob, v_template.language::text),
    'student.gender',            initcap(v_s.gender),
    'student.religion',          v_s.religion,
    'student.b_form_no',         v_s.b_form_no,
    'enrolment.class_name',      v_e.class_name,
    'enrolment.section_name',    v_e.section_name,
    'enrolment.session_name',    v_e.session_name,
    'enrolment.joined_on',       to_char(v_from, 'DD-MM-YYYY'),
    'character.conduct_grade',   p_conduct,
    'character.period_from',     to_char(v_from, 'DD-MM-YYYY'),
    'character.period_to',       to_char(v_to, 'DD-MM-YYYY'),
    'character.remarks',         p_remarks,
    'signatory.name',            coalesce(v_identity ->> 'holder_name', nullif(v_signatory, '')),
    'signatory.designation',     coalesce(v_identity ->> 'designation', initcap(replace(v_role, '_', ' ')))
  );

  v_serial := public.allocate_certificate_serial(
    v_s.campus_id, 'character'::public.certificate_type, v_session.id);
  v_values := v_values || jsonb_build_object('issue.serial_no', v_serial);

  v_pdf_path := v_s.tenant_id::text || '/' || v_s.campus_id::text || '/character/'
                || replace(v_serial, '/', '-') || '.pdf';

  v_seal := case when v_identity is null then null else
    v_identity || jsonb_build_object(
      'signature_anchor_x_mm', v_template.signature_anchor_x_mm::float8,
      'signature_anchor_y_mm', v_template.signature_anchor_y_mm::float8,
      'signature_width_mm',    v_template.signature_width_mm::float8,
      'stamp_anchor_x_mm',     v_template.stamp_anchor_x_mm::float8,
      'stamp_anchor_y_mm',     v_template.stamp_anchor_y_mm::float8,
      'stamp_width_mm',        v_template.stamp_width_mm::float8,
      'stamp_opacity',         v_template.stamp_opacity::float8
    )
  end;

  v_snapshot := jsonb_build_object(
    'template', jsonb_build_object(
      'id',               v_template.id,
      'certificate_type', v_template.certificate_type,
      'board_code',       v_template.board_code,
      'language',         v_template.language,
      'version',          v_template.version,
      'status',           'issued',
      'title',            v_template.title,
      'body_html',        v_template.body_html,
      'page_size',        v_template.page_size
    ),
    'tenant', jsonb_build_object('name', v_s.tenant_name, 'name_ur', v_s.tenant_name_ur),
    'campus', jsonb_build_object('name', v_s.campus_name, 'name_ur', v_s.campus_name_ur,
                                 'code', v_s.campus_code, 'city', v_s.campus_city),
    'letterhead_storage_path',
      (public.resolve_branding(v_s.campus_id, 'letterhead'::public.branding_asset_type)) ->> 'storage_path',
    'logo_storage_path',
      (public.resolve_branding(v_s.campus_id, 'logo'::public.branding_asset_type)) ->> 'storage_path',
    'seal', v_seal,
    'values', v_values
  );

  insert into public.certificate_issue (
    tenant_id, campus_id, student_id, enrolment_id, session_id, certificate_type,
    serial_no, template_id, template_version, language, pdf_path, payload_snapshot, issued_by,
    signing_identity_id
  ) values (
    v_s.tenant_id, v_s.campus_id, p_student_id, v_e.id, v_session.id, 'character',
    v_serial, v_template.id, v_template.version, v_template.language, v_pdf_path, v_snapshot, v_uid,
    v_identity_id
  )
  returning id into v_issue_id;

  return jsonb_build_object(
    'issue_id',            v_issue_id,
    'serial_no',           v_serial,
    'pdf_path',            v_pdf_path,
    'certificate_type',    'character',
    'status',              'issued',
    'template_id',         v_template.id,
    'template_version',    v_template.version,
    'language',            v_template.language,
    'period_from',         v_from,
    'period_to',           v_to,
    'signing_identity_id', v_identity_id,
    'payload_snapshot',    v_snapshot
  );
end;
$$;

revoke execute on function public.issue_character_certificate(
  uuid, text, date, date, text, text, public.certificate_language
) from public, anon;
grant execute on function public.issue_character_certificate(
  uuid, text, date, date, text, text, public.certificate_language
) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- The register shows who signed, and what the document hashes to
-- ═══════════════════════════════════════════════════════════════════════

-- FR-T08's view with four columns appended (CREATE OR REPLACE VIEW can only
-- add at the end, which is all this does). The digest is on the page because
-- an inspector comparing a produced document against the register is exactly
-- the audience for it.
create or replace view public.v_certificate_register
with (security_invoker = true) as
select
  ci.id,
  ci.tenant_id,
  ci.campus_id,
  c.code as campus_code,
  c.name as campus_name,
  ci.certificate_type,
  ci.session_id,
  sess.name as session_name,
  extract(year from sess.starts_on)::int as academic_year,
  ci.serial_seq,
  ci.serial_no,
  ci.status,
  ci.issued_at,
  ci.issued_by,
  issuer.full_name as issued_by_name,
  ci.student_id,
  ci.payload_snapshot -> 'values' ->> 'student.gr_number'      as gr_number,
  ci.payload_snapshot -> 'values' ->> 'student.name_en'        as student_name,
  ci.payload_snapshot -> 'values' ->> 'student.father_name_en' as father_name,
  ci.payload_snapshot -> 'values' ->> 'enrolment.class_name'   as class_name,
  ci.payload_snapshot -> 'values' ->> 'enrolment.section_name' as section_name,
  ci.enrolment_id,
  ci.language,
  ci.template_id,
  ci.template_version,
  ci.pdf_path,
  ci.revoked_at    as cancelled_at,
  ci.revoke_reason as cancelled_reason,
  ci.revoked_by    as cancelled_by,
  canceller.full_name as cancelled_by_name,
  ci.replaced_by_issue_id,
  replacement.serial_no as replaced_by_serial_no,
  superseded.id         as replaces_issue_id,
  superseded.serial_no  as replaces_serial_no,
  ci.original_issue_id,
  -- FR-T09.
  ci.pdf_sha256,
  ci.signing_identity_id,
  -- From the snapshot rather than from the signing_identity row, for the
  -- same reason the student's name comes from the snapshot: the register
  -- records what the DOCUMENT says. A holder later renamed does not rename
  -- themselves on a certificate they signed in 2026.
  ci.payload_snapshot -> 'values' ->> 'signatory.name'        as signed_by_name,
  ci.payload_snapshot -> 'values' ->> 'signatory.designation' as signed_by_designation
from public.certificate_issue ci
join public.campus c on c.id = ci.campus_id
join public.academic_session sess on sess.id = ci.session_id
left join public.app_user issuer on issuer.user_id = ci.issued_by
left join public.app_user canceller on canceller.user_id = ci.revoked_by
left join public.certificate_issue replacement on replacement.id = ci.replaced_by_issue_id
left join public.certificate_issue superseded on superseded.replaced_by_issue_id = ci.id;

revoke all on public.v_certificate_register from public, anon;
grant select on public.v_certificate_register to authenticated;
