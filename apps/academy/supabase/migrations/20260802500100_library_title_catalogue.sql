-- FR-O01: bibliographic title catalogue with ISBN.
--
-- A work is catalogued ONCE (library_title); every physical copy of it (FR-O02)
-- hangs off that record. The ISBN is the natural key, with three traps this
-- migration is built around:
--
--  * ISBN-10 vs ISBN-13 and hyphenation. normalise_isbn13() strips hyphens and
--    spaces, validates the checksum, upgrades an ISBN-10 to its 978-prefixed
--    ISBN-13 and returns NULL for a blank. isbn13 is a STORED GENERATED column
--    over raw_isbn, so "978-969-352-601-1" and "9789693526011" are the same
--    value by construction and the unique index sees them as a duplicate. An
--    invalid checksum raises ISBN_INVALID before any uniqueness check.
--  * Locally printed Urdu / Islamiyat / board-notes titles carry no ISBN at all,
--    so isbn13 is nullable. Postgres treats NULLs as distinct in a unique index,
--    which is exactly the behaviour needed (no conflict between NULL-ISBN titles).
--  * Urdu search. A GIN index over to_tsvector('simple', title || title_ur) keeps
--    search under 500 ms on a 20,000-title catalogue; the 'simple' configuration
--    does no English stemming, so Urdu script tokens match as written.
--
-- Writes go through save_library_title() (library staff only). Cover images live
-- in the private library-covers bucket; the student portal is served a signed,
-- transformed (<= 200 KB) rendition by /api/library-covers/[titleId].
--
-- Shared helpers used by the whole library module (FR-O01..O08) are created here.

-- ── permission catalogue ─────────────────────────────────────────────────────

insert into public.permission (code, module, label) values
  ('library.read',   'Library', 'View the library catalogue and loans'),
  ('library.manage', 'Library', 'Catalogue titles, register copies and run the circulation desk')
on conflict (code) do nothing;

insert into public.role_permission (role_id, permission_code)
select r.id, p.code
  from public.role r
  join lateral (values
    ('super_admin',    'library.read'), ('super_admin',    'library.manage'),
    ('owner',          'library.read'), ('owner',          'library.manage'),
    ('principal',      'library.read'), ('principal',      'library.manage'),
    ('vice_principal', 'library.read'),
    ('librarian',      'library.read'), ('librarian',      'library.manage'),
    ('accountant',     'library.read')
  ) as p(role_code, code) on p.role_code = r.code
 where r.tenant_id is null
on conflict do nothing;

insert into public.role_permission (role_id, permission_code)
select tr.id, tmpl_rp.permission_code
  from public.role tr
  join public.role tmpl on tmpl.tenant_id is null and tmpl.code = tr.code
  join public.role_permission tmpl_rp on tmpl_rp.role_id = tmpl.id
 where tr.tenant_id is not null and tmpl_rp.permission_code in ('library.read', 'library.manage')
on conflict do nothing;

-- ── shared helpers ───────────────────────────────────────────────────────────

-- The roles that run the library desk. Teachers, parents and students read.
create or replace function app.fn_library_staff()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner', 'principal', 'librarian');
$$;
grant execute on function app.fn_library_staff() to authenticated;

create or replace function app.fn_library_campus_ok(p_campus_id uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() in ('super_admin', 'owner') or p_campus_id = any (app.auth_campus_ids());
$$;
grant execute on function app.fn_library_campus_ok(uuid) to authenticated;

-- ── ISBN normalisation ───────────────────────────────────────────────────────

create or replace function public.normalise_isbn13(p_raw text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v     text;
  v_sum int := 0;
  i     int;
  d     int;
begin
  if p_raw is null then
    return null;
  end if;
  v := upper(regexp_replace(p_raw, '[[:space:]-]', '', 'g'));
  if v = '' then
    return null;
  end if;
  if v !~ '^[0-9]{9}[0-9X]$' and v !~ '^[0-9]{13}$' then
    raise exception 'ISBN_INVALID' using errcode = '22023';
  end if;

  if length(v) = 10 then
    for i in 1..10 loop
      d := case when substr(v, i, 1) = 'X' then 10 else substr(v, i, 1)::int end;
      v_sum := v_sum + d * (11 - i);
    end loop;
    if v_sum % 11 <> 0 then
      raise exception 'ISBN_INVALID' using errcode = '22023';
    end if;
    v := '978' || substr(v, 1, 9);
    v_sum := 0;
    for i in 1..12 loop
      v_sum := v_sum + substr(v, i, 1)::int * case when i % 2 = 1 then 1 else 3 end;
    end loop;
    return v || ((10 - v_sum % 10) % 10)::text;
  end if;

  if substr(v, 1, 3) not in ('978', '979') then
    raise exception 'ISBN_INVALID' using errcode = '22023';
  end if;
  for i in 1..12 loop
    v_sum := v_sum + substr(v, i, 1)::int * case when i % 2 = 1 then 1 else 3 end;
  end loop;
  if (10 - v_sum % 10) % 10 <> substr(v, 13, 1)::int then
    raise exception 'ISBN_INVALID' using errcode = '22023';
  end if;
  return v;
end;
$$;
grant execute on function public.normalise_isbn13(text) to authenticated;

-- ── library_title ────────────────────────────────────────────────────────────

create table public.library_title (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  raw_isbn    text,
  isbn13      text generated always as (public.normalise_isbn13(raw_isbn)) stored,
  title       text not null check (char_length(btrim(title)) between 1 and 300),
  title_ur    text check (title_ur is null or char_length(title_ur) <= 300),
  author      text check (author is null or char_length(author) <= 200),
  publisher   text check (publisher is null or char_length(publisher) <= 200),
  edition     text check (edition is null or char_length(edition) <= 50),
  language    text not null default 'en' check (language in ('en', 'ur', 'ar', 'pa', 'sd', 'other')),
  dewey       text check (dewey is null or dewey ~ '^[0-9]{1,3}(\.[0-9]+)?$'),
  subject_id  uuid references public.subject(id) on delete set null,
  cover_path  text,
  created_by  uuid references public.app_user(user_id),
  created_at  timestamptz not null default now(),
  constraint chk_library_title_isbn13 check (isbn13 is null or char_length(isbn13) = 13)
);

create unique index uq_library_title_isbn on public.library_title (tenant_id, isbn13) where isbn13 is not null;
create index idx_library_title_fts on public.library_title
  using gin (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(title_ur, '')));
create index idx_library_title_tenant on public.library_title (tenant_id);
create index idx_library_title_subject on public.library_title (subject_id);

create trigger library_title_audit after insert or update or delete on public.library_title
  for each row execute function app.tg_audit_row();

alter table public.library_title enable row level security;
create policy library_title_tenant_scope on public.library_title for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- ── save_library_title ───────────────────────────────────────────────────────

create or replace function public.save_library_title(
  p_title text, p_raw_isbn text default null, p_title_ur text default null, p_author text default null,
  p_publisher text default null, p_edition text default null, p_language text default 'en',
  p_dewey text default null, p_subject_id uuid default null, p_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'TITLE_REQUIRED' using errcode = '23514';
  end if;
  if p_subject_id is not null and not exists (select 1 from public.subject where id = p_subject_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_id is null then
    insert into public.library_title (tenant_id, raw_isbn, title, title_ur, author, publisher, edition, language, dewey, subject_id, created_by)
    values (app.auth_tenant_id(), nullif(btrim(p_raw_isbn), ''), btrim(p_title), nullif(btrim(p_title_ur), ''), nullif(btrim(p_author), ''),
            nullif(btrim(p_publisher), ''), nullif(btrim(p_edition), ''), coalesce(p_language, 'en'), nullif(btrim(p_dewey), ''), p_subject_id, (select auth.uid()))
    returning id into v_id;
  else
    update public.library_title
       set raw_isbn = nullif(btrim(p_raw_isbn), ''), title = btrim(p_title), title_ur = nullif(btrim(p_title_ur), ''), author = nullif(btrim(p_author), ''),
           publisher = nullif(btrim(p_publisher), ''), edition = nullif(btrim(p_edition), ''), language = coalesce(p_language, 'en'),
           dewey = nullif(btrim(p_dewey), ''), subject_id = p_subject_id
     where id = p_id and tenant_id = app.auth_tenant_id()
     returning id into v_id;
    if v_id is null then
      raise exception 'TITLE_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
exception when unique_violation then
  raise exception 'ISBN_ALREADY_CATALOGUED' using errcode = '23505';
end;
$$;
revoke execute on function public.save_library_title(text, text, text, text, text, text, text, text, uuid, uuid) from public, anon;
grant execute on function public.save_library_title(text, text, text, text, text, text, text, text, uuid, uuid) to authenticated;

create or replace function public.set_library_title_cover(p_title_id uuid, p_cover_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not app.fn_library_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_cover_path is not null and (storage.foldername(p_cover_path))[1] is distinct from app.auth_tenant_id()::text then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.library_title set cover_path = p_cover_path where id = p_title_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'TITLE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_library_title_cover(uuid, text) from public, anon;
grant execute on function public.set_library_title_cover(uuid, text) to authenticated;

-- ── search ───────────────────────────────────────────────────────────────────
-- Word-prefix match over title and Urdu title (same expression as the GIN
-- index, so the index is used), or an exact ISBN lookup when the input is a
-- valid ISBN.

create or replace function public.search_library_titles(p_query text, p_limit int default 25)
returns table (id uuid, title text, title_ur text, author text, isbn13 text, language text, cover_path text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_q    text := btrim(coalesce(p_query, ''));
  v_isbn text;
  v_tsq  tsquery;
  v_lim  int := least(greatest(coalesce(p_limit, 25), 1), 100);
begin
  if app.auth_tenant_id() is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if v_q = '' then
    return query select t.id, t.title, t.title_ur, t.author, t.isbn13, t.language, t.cover_path
                   from public.library_title t where t.tenant_id = app.auth_tenant_id() order by t.title limit v_lim;
    return;
  end if;

  if v_q ~ '^[0-9Xx -]{10,17}$' then
    begin
      v_isbn := public.normalise_isbn13(v_q);
    exception when others then
      v_isbn := null;
    end;
    if v_isbn is not null then
      return query select t.id, t.title, t.title_ur, t.author, t.isbn13, t.language, t.cover_path
                     from public.library_title t where t.tenant_id = app.auth_tenant_id() and t.isbn13 = v_isbn limit v_lim;
      return;
    end if;
  end if;

  select to_tsquery('simple', string_agg(w || ':*', ' & ')) into v_tsq
    from (select regexp_replace(x, '[&|!():*''\\<>,"]', '', 'g') as w from regexp_split_to_table(v_q, '[[:space:]]+') x) s
   where w <> '';
  if v_tsq is null then
    return;
  end if;
  return query
    select t.id, t.title, t.title_ur, t.author, t.isbn13, t.language, t.cover_path
      from public.library_title t
     where t.tenant_id = app.auth_tenant_id()
       and to_tsvector('simple', coalesce(t.title, '') || ' ' || coalesce(t.title_ur, '')) @@ v_tsq
     order by t.title
     limit v_lim;
end;
$$;
revoke execute on function public.search_library_titles(text, int) from public, anon;
grant execute on function public.search_library_titles(text, int) to authenticated;

-- ── cover storage ────────────────────────────────────────────────────────────
-- Private bucket. Originals up to 5 MB are accepted (a 2 MB phone photo is
-- normal); readers are only ever handed a signed URL with a width/quality
-- transform, so the student portal receives <= 200 KB.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('library-covers', 'library-covers', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

create policy library_covers_read on storage.objects for select to authenticated
  using (bucket_id = 'library-covers' and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text);
create policy library_covers_librarian_write on storage.objects for insert to authenticated
  with check (bucket_id = 'library-covers' and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text and app.fn_library_staff());
create policy library_covers_librarian_update on storage.objects for update to authenticated
  using (bucket_id = 'library-covers' and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text and app.fn_library_staff())
  with check (bucket_id = 'library-covers' and (storage.foldername(objects.name))[1] = app.auth_tenant_id()::text and app.fn_library_staff());
