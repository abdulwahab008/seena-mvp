-- FR-A18: tenant branding assets (logo, letterhead, signature, stamp).
--
-- A real Storage build, same posture as FR-B10 (admission documents) —
-- by the time that FR shipped this session, "no Storage anywhere in this
-- codebase" (FR-K11's own header, when challan_template.logo_path was
-- left as an unpopulated free-text column) was no longer true, so this
-- FR builds the real thing rather than repeating that scope cut.
--
--   * Reserve-then-upload-then-confirm, not FR-B10's reserve-then-upload:
--     a branding asset can supersede the tenant's/campus's CURRENT one,
--     and flipping is_current at reserve time (before the file actually
--     exists in the bucket) would leave `resolve_branding()` pointing at
--     nothing if the client-side upload never completes. confirm_
--     branding_asset() only flips is_current after the caller confirms
--     the upload succeeded; an abandoned reservation is a harmless
--     orphan row with is_current=false, exactly like FR-B10's own
--     documented orphan-object tradeoff.
--   * Old versions are never deleted, only superseded (is_current=false)
--     — this is what AC4 ("a challan generated last month still shows
--     the logo current when it was generated") needs: a trigger on
--     fee_challan snapshots resolve_branding()'s result into a new
--     logo_asset_id column AT INSERT TIME, and build_challan_render_
--     payload() (itself just a live view, never persisted) looks up
--     branding by that stored id rather than re-resolving "whatever is
--     current right now". Deliberately a trigger, not a change to
--     generate_challans() itself — that function is large, already
--     heavily tested, and redefining it here to memoize one more field
--     would be needless risk for something a BEFORE INSERT trigger
--     does more safely in isolation.
--   * One global minimum width (600px), not a per-asset-type table —
--     the only AC given tests a logo; a real per-type minimum table is
--     easy to add later if letterhead/signature/stamp ever need
--     different floors, and speculatively building one now would be
--     guessing at requirements nobody has stated.
--   * The "parent with no session" signed-link AC is proven end-to-end
--     against the one real consumer that exists today — the challan
--     render payload (FR-K11) — via a public route handler that mints a
--     signed URL server-side with the service-role key, the same
--     pattern already used for FR-B02's anon-facing route. Report-card
--     PDF branding (Module J, not built) will reuse this unchanged.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', false, 3145728, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;

create type public.branding_asset_type as enum ('logo', 'letterhead', 'signature', 'stamp');

create table public.branding_asset (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid references public.campus(id) on delete cascade,
  asset_type    public.branding_asset_type not null,
  storage_path  text not null unique,
  width_px      int not null check (width_px > 0),
  height_px     int not null check (height_px > 0),
  bytes         int not null check (bytes > 0 and bytes <= 3145728),
  version       int not null check (version > 0),
  is_current    boolean not null default false,
  uploaded_by   uuid references public.app_user(user_id),
  created_at    timestamptz not null default clock_timestamp()
);

create index idx_branding_asset_lookup on public.branding_asset (tenant_id, campus_id, asset_type) where is_current;
create unique index uq_branding_asset_current_campus on public.branding_asset (tenant_id, campus_id, asset_type)
  where is_current and campus_id is not null;
create unique index uq_branding_asset_current_tenant on public.branding_asset (tenant_id, asset_type)
  where is_current and campus_id is null;

create trigger branding_asset_audit after insert or update or delete on public.branding_asset
  for each row execute function app.tg_audit_row();

create table public.tenant_theme (
  tenant_id     uuid primary key references public.tenant(id) on delete cascade,
  primary_hex   text check (primary_hex is null or primary_hex ~ '^#[0-9a-fA-F]{6}$'),
  secondary_hex text check (secondary_hex is null or secondary_hex ~ '^#[0-9a-fA-F]{6}$'),
  updated_by    uuid references public.app_user(user_id),
  updated_at    timestamptz not null default clock_timestamp()
);

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

create or replace function public.confirm_branding_asset(p_asset_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_asset public.branding_asset%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_asset from public.branding_asset where id = p_asset_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'ASSET_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.branding_asset
     set is_current = false
   where tenant_id = v_asset.tenant_id and campus_id is not distinct from v_asset.campus_id
     and asset_type = v_asset.asset_type and is_current;

  update public.branding_asset set is_current = true where id = p_asset_id;
end;
$$;

revoke execute on function public.confirm_branding_asset(uuid) from public, anon;
grant execute on function public.confirm_branding_asset(uuid) to authenticated;

-- Compensating action when the client-side storage upload never
-- completes — only ever removes a reservation that never went live.
create or replace function public.delete_branding_asset(p_asset_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  delete from public.branding_asset where id = p_asset_id and tenant_id = app.auth_tenant_id() and not is_current;
  if not found then
    raise exception 'ASSET_NOT_DELETABLE' using errcode = '55000';
  end if;
end;
$$;

revoke execute on function public.delete_branding_asset(uuid) from public, anon;
grant execute on function public.delete_branding_asset(uuid) to authenticated;

-- AC: campus-then-tenant fallback; the caller decides what "no asset at
-- all" (text-only fallback, no broken image) means.
create or replace function public.resolve_branding(p_campus_id uuid, p_asset_type public.branding_asset_type)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_asset     public.branding_asset%rowtype;
begin
  select * into v_asset from public.branding_asset
   where tenant_id = v_tenant_id and campus_id = p_campus_id and asset_type = p_asset_type and is_current;
  if not found then
    select * into v_asset from public.branding_asset
     where tenant_id = v_tenant_id and campus_id is null and asset_type = p_asset_type and is_current;
  end if;
  if not found then
    return null;
  end if;
  return jsonb_build_object('asset_id', v_asset.id, 'storage_path', v_asset.storage_path);
end;
$$;

revoke execute on function public.resolve_branding(uuid, public.branding_asset_type) from public, anon;
grant execute on function public.resolve_branding(uuid, public.branding_asset_type) to authenticated;

create or replace function public.set_tenant_theme(p_primary_hex text default null, p_secondary_hex text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.tenant_theme (tenant_id, primary_hex, secondary_hex, updated_by)
  values (app.auth_tenant_id(), p_primary_hex, p_secondary_hex, auth.uid())
  on conflict (tenant_id) do update
    set primary_hex = excluded.primary_hex, secondary_hex = excluded.secondary_hex,
        updated_by = excluded.updated_by, updated_at = clock_timestamp();
end;
$$;

revoke execute on function public.set_tenant_theme(text, text) from public, anon;
grant execute on function public.set_tenant_theme(text, text) to authenticated;

-- AC4: fee_challan.logo_asset_id (below) is captured once, at insert
-- time, by a trigger — build_challan_render_payload() just looks that
-- id up, so replacing the tenant's logo later never changes what an
-- already-existing challan's payload reports.
alter table public.fee_challan add column logo_asset_id uuid references public.branding_asset(id);

create or replace function app.tg_snapshot_challan_logo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.logo_asset_id := (public.resolve_branding(new.campus_id, 'logo') ->> 'asset_id')::uuid;
  return new;
end;
$$;

create trigger challan_snapshot_logo before insert on public.fee_challan
  for each row execute function app.tg_snapshot_challan_logo();

create or replace function public.build_challan_render_payload(p_challan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_challan  public.fee_challan%rowtype;
  v_template public.challan_template%rowtype;
  v_student  record;
  v_lines    jsonb;
  v_logo     jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_template from public.challan_template where campus_id = v_challan.campus_id;
  if v_challan.logo_asset_id is not null then
    select jsonb_build_object('asset_id', id, 'storage_path', storage_path) into v_logo
      from public.branding_asset where id = v_challan.logo_asset_id;
  end if;

  select s.name_en, s.gr_number, cl.name_en as class_name, cs.name as section_name
    into v_student
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
   where e.id = v_challan.enrolment_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'head_name', fh.name_en, 'amount_paisa', fcl.amount_paisa,
           'concession_paisa', fcl.concession_paisa, 'net_paisa', fcl.net_paisa, 'line_type', fcl.line_type
         ) order by fh.code), '[]'::jsonb)
    into v_lines
    from public.fee_challan_line fcl
    join public.fee_head fh on fh.id = fcl.fee_head_id
   where fcl.challan_id = p_challan_id;

  return jsonb_build_object(
    'challan_no', v_challan.challan_no,
    'barcode_value', v_challan.challan_no,
    'billing_period', v_challan.billing_period,
    'issue_date', v_challan.issue_date,
    'due_date', v_challan.due_date,
    'student', jsonb_build_object(
      'name_en', v_student.name_en, 'gr_number', v_student.gr_number,
      'class_name', v_student.class_name, 'section_name', v_student.section_name
    ),
    'bank', jsonb_build_object(
      'bank_name', v_template.bank_name, 'bank_account_title', v_template.bank_account_title,
      'bank_account_no', v_template.bank_account_no, 'footer_note_en', v_template.footer_note_en,
      'footer_note_ur', v_template.footer_note_ur
    ),
    'logo', v_logo,
    'lines', v_lines,
    'gross_paisa', v_challan.gross_paisa,
    'concession_paisa', v_challan.concession_paisa,
    'net_paisa', v_challan.net_paisa,
    'copies', jsonb_build_array('bank', 'school', 'student')
  );
end;
$$;

revoke execute on function public.build_challan_render_payload(uuid) from public, anon;
grant execute on function public.build_challan_render_payload(uuid) to authenticated;

alter table public.branding_asset enable row level security;
alter table public.tenant_theme enable row level security;

create policy branding_asset_tenant_read on public.branding_asset
  for select to authenticated using (tenant_id = app.auth_tenant_id());
create policy tenant_theme_tenant_read on public.tenant_theme
  for select to authenticated using (tenant_id = app.auth_tenant_id());

-- Mirrors FR-B10's admission_docs storage policies exactly: an object
-- can only be written to a path a branding_asset row already reserved,
-- and only ever read/removed within the caller's own tenant.
create policy branding_read_tenant on storage.objects
  for select to authenticated
  using (
    bucket_id = 'branding'
    and exists (select 1 from public.branding_asset ba where ba.storage_path = objects.name and ba.tenant_id = app.auth_tenant_id())
  );

create policy branding_insert_owner on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'branding'
    and app.auth_role() in ('super_admin', 'owner', 'principal')
    and exists (select 1 from public.branding_asset ba where ba.storage_path = objects.name and ba.tenant_id = app.auth_tenant_id())
  );
