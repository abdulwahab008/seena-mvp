-- FR-O02: per-copy accession and barcode register.
--
-- Every physical copy is its own row (library_copy) with an accession number and a
-- barcode, both unique per school. Three rules are enforced by the schema, not by the UI:
--
--  * Accession numbers are NEVER reused. The unique index uq_library_copy_accession spans
--    every status including written_off, and copies cannot be deleted, because the school
--    auditor reconciles the physical accession register against the shelf.
--  * Copies belong to a campus. library_copy_campus_scope limits every read to the caller's
--    campuses, so v_title_availability (security_invoker) can never show one campus's stock
--    as available at another. A student of Gulberg sees "2 of 6", never Johar Town's copies.
--  * A bulk CSV import is all-or-nothing: import_library_copies() inserts nothing when any
--    row is bad and reports the offending row numbers (1-based data rows) instead.
--
-- Status moves (issued, reserved_hold) are made only by the circulation functions of
-- FR-O04..O08; set_library_copy_status() covers the librarian's own transitions
-- (repair, lost, found). Rows are never updated or deleted directly by clients.

create type public.library_copy_status as enum ('available', 'issued', 'reserved_hold', 'in_repair', 'lost', 'written_off');

create table public.library_copy (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid not null references public.campus(id) on delete cascade,
  title_id      uuid not null references public.library_title(id),
  accession_no  text not null check (char_length(btrim(accession_no)) between 1 and 50),
  barcode       text not null check (char_length(btrim(barcode)) between 1 and 50),
  status        public.library_copy_status not null default 'available',
  shelf         text check (shelf is null or char_length(shelf) <= 50),
  purchase_cost bigint check (purchase_cost is null or purchase_cost >= 0),
  acquired_on   date,
  -- the vendor register arrives with the procurement module; a plain uuid until then
  vendor_id     uuid,
  created_by    uuid references public.app_user(user_id),
  created_at    timestamptz not null default now()
);

create unique index uq_library_copy_accession on public.library_copy (tenant_id, accession_no);
create unique index uq_library_copy_barcode on public.library_copy (tenant_id, barcode);
create index idx_library_copy_title on public.library_copy (title_id, campus_id, status);
create index idx_library_copy_campus on public.library_copy (campus_id, status);
create index idx_library_copy_tenant on public.library_copy (tenant_id);

create trigger library_copy_audit after insert or update or delete on public.library_copy
  for each row execute function app.tg_audit_row();

create or replace function app.tg_library_copy_no_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'LIBRARY_COPY_NOT_DELETABLE' using errcode = '42501';
end;
$$;
create trigger library_copy_no_delete before delete on public.library_copy
  for each row execute function app.tg_library_copy_no_delete();

alter table public.library_copy enable row level security;
create policy library_copy_campus_scope on public.library_copy for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_library_campus_ok(campus_id));
revoke insert, update, delete on public.library_copy from authenticated, anon;

-- ── availability per title and campus ────────────────────────────────────────
-- total excludes written-off copies (they are off the shelf); available counts only
-- copies that can be issued right now (not issued, held, in repair or lost).

create view public.v_title_availability with (security_invoker = true) as
select c.tenant_id, c.title_id, c.campus_id,
       count(*) filter (where c.status <> 'written_off')::int as total_copies,
       count(*) filter (where c.status = 'available')::int as available_copies
  from public.library_copy c
 group by c.tenant_id, c.title_id, c.campus_id;
grant select on public.v_title_availability to authenticated;

-- ── register one copy ────────────────────────────────────────────────────────

create or replace function public.register_library_copy(
  p_title_id uuid, p_campus_id uuid, p_accession_no text, p_barcode text,
  p_shelf text default null, p_purchase_cost bigint default null, p_acquired_on date default null, p_vendor_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id         uuid;
  v_constraint text;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not app.fn_library_campus_ok(p_campus_id) or not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if not exists (select 1 from public.library_title where id = p_title_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'TITLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if btrim(coalesce(p_accession_no, '')) = '' or btrim(coalesce(p_barcode, '')) = '' then
    raise exception 'ACCESSION_AND_BARCODE_REQUIRED' using errcode = '23514';
  end if;

  insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode, shelf, purchase_cost, acquired_on, vendor_id, created_by)
  values (app.auth_tenant_id(), p_campus_id, p_title_id, btrim(p_accession_no), btrim(p_barcode), nullif(btrim(p_shelf), ''), p_purchase_cost, p_acquired_on, p_vendor_id, (select auth.uid()))
  returning id into v_id;
  return v_id;
exception when unique_violation then
  get stacked diagnostics v_constraint = constraint_name;
  if v_constraint = 'uq_library_copy_accession' then
    raise exception 'DUPLICATE_ACCESSION' using errcode = '23505';
  end if;
  raise exception 'DUPLICATE_BARCODE' using errcode = '23505';
end;
$$;
revoke execute on function public.register_library_copy(uuid, uuid, text, text, text, bigint, date, uuid) from public, anon;
grant execute on function public.register_library_copy(uuid, uuid, text, text, text, bigint, date, uuid) to authenticated;

-- ── atomic CSV import ────────────────────────────────────────────────────────
-- p_rows: [{ title_id | isbn, accession_no, barcode, shelf?, purchase_cost? (paisa), acquired_on? }].
-- Returns {ok, imported, errors:[{row, code}], duplicate_barcode_rows:[n]}. Nothing is written when
-- ok is false. Row numbers are 1-based positions in p_rows (CSV data rows, header excluded).

create or replace function app.fn_isbn_or_null(p_raw text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
begin
  return public.normalise_isbn13(p_raw);
exception when others then
  return null;
end;
$$;

create or replace function public.import_library_copies(p_campus_id uuid, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_errors  jsonb;
  v_dup_b   jsonb;
  v_n       int;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not app.fn_library_campus_ok(p_campus_id) or not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'IMPORT_EMPTY' using errcode = '22023';
  end if;
  if jsonb_array_length(p_rows) > 5000 then
    raise exception 'IMPORT_TOO_LARGE' using errcode = '22023';
  end if;

  create temp table if not exists pg_temp.lib_import_parsed (
    n int, title_id uuid, accession text, barcode text, shelf text, cost bigint, acquired date
  ) on commit drop;
  truncate pg_temp.lib_import_parsed;

  insert into pg_temp.lib_import_parsed
  select t.n::int,
         coalesce(
           (select lt.id from public.library_title lt
             where lt.tenant_id = v_tenant and lt.id = case when t.x ->> 'title_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (t.x ->> 'title_id')::uuid end),
           (select lt.id from public.library_title lt where lt.tenant_id = v_tenant and lt.isbn13 = app.fn_isbn_or_null(t.x ->> 'isbn') and app.fn_isbn_or_null(t.x ->> 'isbn') is not null)
         ),
         nullif(btrim(t.x ->> 'accession_no'), ''),
         nullif(btrim(t.x ->> 'barcode'), ''),
         nullif(btrim(t.x ->> 'shelf'), ''),
         case when t.x ->> 'purchase_cost' ~ '^[0-9]{1,15}$' then (t.x ->> 'purchase_cost')::bigint end,
         case when t.x ->> 'acquired_on' ~ '^\d{4}-\d{2}-\d{2}$' then (t.x ->> 'acquired_on')::date end
    from jsonb_array_elements(p_rows) with ordinality as t(x, n);

  select coalesce(jsonb_agg(jsonb_build_object('row', e.n, 'code', e.code) order by e.n, e.code), '[]'::jsonb)
    into v_errors
    from (
      select n, 'MISSING_FIELD' as code from pg_temp.lib_import_parsed where accession is null or barcode is null
      union all
      select n, 'TITLE_NOT_FOUND' from pg_temp.lib_import_parsed where title_id is null
      union all
      select p.n, 'DUPLICATE_BARCODE'
        from (select pp.*, row_number() over (partition by barcode order by n) as rn from pg_temp.lib_import_parsed pp where barcode is not null) p
       where p.rn > 1 or exists (select 1 from public.library_copy c where c.tenant_id = v_tenant and c.barcode = p.barcode)
      union all
      select p.n, 'DUPLICATE_ACCESSION'
        from (select pp.*, row_number() over (partition by accession order by n) as rn from pg_temp.lib_import_parsed pp where accession is not null) p
       where p.rn > 1 or exists (select 1 from public.library_copy c where c.tenant_id = v_tenant and c.accession_no = p.accession)
    ) e;

  if jsonb_array_length(v_errors) > 0 then
    select coalesce(jsonb_agg(distinct (x ->> 'row')::int order by (x ->> 'row')::int), '[]'::jsonb)
      into v_dup_b from jsonb_array_elements(v_errors) x where x ->> 'code' = 'DUPLICATE_BARCODE';
    return jsonb_build_object('ok', false, 'imported', 0, 'errors', v_errors, 'duplicate_barcode_rows', v_dup_b);
  end if;

  insert into public.library_copy (tenant_id, campus_id, title_id, accession_no, barcode, shelf, purchase_cost, acquired_on, created_by)
  select v_tenant, p_campus_id, title_id, accession, barcode, shelf, cost, acquired, (select auth.uid())
    from pg_temp.lib_import_parsed order by n;
  get diagnostics v_n = row_count;
  return jsonb_build_object('ok', true, 'imported', v_n, 'errors', '[]'::jsonb, 'duplicate_barcode_rows', '[]'::jsonb);
end;
$$;
revoke execute on function public.import_library_copies(uuid, jsonb) from public, anon;
grant execute on function public.import_library_copies(uuid, jsonb) to authenticated;

-- ── librarian status moves ───────────────────────────────────────────────────
-- available <-> in_repair, available/in_repair -> lost, lost -> available (found).
-- issued and reserved_hold belong to circulation; written_off to FR-O08.

create or replace function public.set_library_copy_status(p_copy_id uuid, p_status public.library_copy_status)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.library_copy%rowtype;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_c from public.library_copy where id = p_copy_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'COPY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_library_campus_ok(v_c.campus_id) then
    raise exception 'CAMPUS_NOT_ALLOWED' using errcode = '42501';
  end if;
  if not (
       (v_c.status = 'available' and p_status in ('in_repair', 'lost'))
    or (v_c.status = 'in_repair' and p_status in ('available', 'lost'))
    or (v_c.status = 'lost' and p_status = 'available')
  ) then
    raise exception 'INVALID_STATUS_CHANGE' using errcode = '55000';
  end if;
  update public.library_copy set status = p_status where id = p_copy_id;
end;
$$;
revoke execute on function public.set_library_copy_status(uuid, public.library_copy_status) from public, anon;
grant execute on function public.set_library_copy_status(uuid, public.library_copy_status) to authenticated;
