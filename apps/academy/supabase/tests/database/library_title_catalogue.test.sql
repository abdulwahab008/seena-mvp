-- pgTAP tests for FR-O01: bibliographic title catalogue with ISBN.
begin;
select plan(26);

select public.provision_tenant('test-libtitle-co', 'Lib Title Co', 'owner@libtitle.test');
select id as tenant_id from public.tenant where slug = 'test-libtitle-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-libtitle-other', 'Other Lib Co', 'owner@otherlibtitle.test');
select id as other_tenant_id from public.tenant where slug = 'test-libtitle-other' \gset

select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as stud_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'lib_uid', 'l@libtitle.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@libtitle.test', 'authenticated', 'authenticated', 'x'),
  (:'stud_uid', 's@libtitle.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'stud_uid', :'tenant_id', 'student', 'Student');
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'ISL', 'Islamiyat', 'اسلامیات');
select id as isl from public.subject where tenant_id = :'tenant_id' and code = 'ISL' \gset

-- timing helper (runs the statement and returns elapsed milliseconds)
create function pg_temp.elapsed_ms(p_sql text) returns numeric language plpgsql as $$
declare t0 timestamptz := clock_timestamp();
begin
  execute p_sql;
  return extract(epoch from clock_timestamp() - t0) * 1000;
end;
$$;
grant execute on function pg_temp.elapsed_ms(text) to public;

-- ── ISBN normalisation ───────────────────────────────────────────────────
select is(public.normalise_isbn13('978-969-352-601-1'), '9789693526011', 'hyphens are stripped');
select is(public.normalise_isbn13('0-306-40615-2'), '9780306406157', 'a valid ISBN-10 is upgraded to ISBN-13');
select is(public.normalise_isbn13('  '), null, 'a blank is NULL');
select throws_ok($$ select public.normalise_isbn13('9789693526012') $$, 'ISBN_INVALID', 'a bad checksum is rejected');
select throws_ok($$ select public.normalise_isbn13('0-306-40615-3') $$, 'ISBN_INVALID', 'a bad ISBN-10 checksum is rejected');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: hyphenated duplicate of an existing ISBN ─────────────────────────
select public.save_library_title('Pakistan Studies 9', '9789693526011', 'مطالعہ پاکستان', 'Punjab Board', 'PCTB', '2nd', 'en', '954', :'isl'::uuid) as t1 \gset
select is((select isbn13 from public.library_title where id = :'t1'::uuid), '9789693526011', 'the title is stored with its normalised ISBN-13');
select throws_ok($$ select public.save_library_title('Pakistan Studies 9 (reprint)', '978-969-352-601-1') $$, 'ISBN_ALREADY_CATALOGUED', 'AC1: the hyphenated form of an existing ISBN is rejected as ISBN_ALREADY_CATALOGUED');
select throws_ok($$ select public.save_library_title('Reprint', '0-306-40615-3') $$, 'ISBN_INVALID', 'AC1: the checksum is validated before uniqueness');
select public.save_library_title('Chemistry 10', '0-306-40615-2') as t2 \gset
select throws_ok(format($$ select public.save_library_title('Chemistry 10', '978-969-352-601-1', null, null, null, null, 'en', null, null, %L) $$, :'t2'), 'ISBN_ALREADY_CATALOGUED', 'editing a title onto another title''s ISBN is rejected');
select is((select isbn13 from public.library_title where id = :'t2'::uuid), '9780306406157', 'and the ISBN-10 entered earlier was stored as its ISBN-13');

-- ── AC2: no ISBN is fine, and does not conflict ───────────────────────────
select public.save_library_title('Islamiyat Notes Class 9', null, 'اسلامیات نوٹس', null, 'Local Press', null, 'ur') as n1 \gset
select lives_ok($$ select public.save_library_title('Islamiyat Guide Class 10', null, 'اسلامیات گائیڈ', null, 'Local Press', null, 'ur') $$, 'AC2: a second title with a NULL ISBN raises no conflict');
select lives_ok($$ select public.save_library_title('Blank ISBN title', '   ') $$, 'AC2: a blank ISBN is stored as NULL as well');
select is((select count(*) from public.library_title where tenant_id = app.auth_tenant_id() and isbn13 is null), 3::bigint, 'three NULL-ISBN titles coexist');

-- ── write access ──────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.save_library_title('Sneaky') $$, 'FORBIDDEN', 'a teacher cannot catalogue titles');
select throws_ok($$ insert into public.library_title (tenant_id, title) values (app.auth_tenant_id(), 'Direct') $$, '42501', null, 'nor write the table directly (RLS)');
select is((select count(*) from public.library_title), 5::bigint, 'but a teacher can read the catalogue');

-- ── AC3: Urdu search over a 20,000-title catalogue ────────────────────────
reset role;
insert into public.library_title (tenant_id, title, title_ur, language)
select :'tenant_id', 'Catalogue filler ' || i, case when i % 400 = 0 then 'معاشرتی علوم جماعت ' || i else 'دوسری کتاب ' || i end, 'ur'
  from generate_series(1, 20000) i;
analyze public.library_title;
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'stud_uid', 'tenant_id', :'tenant_id', 'app_role', 'student', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.search_library_titles('معاشرتی علوم', 100)), 50::bigint, 'AC3: the Urdu string finds exactly the 50 matching titles');
select ok(pg_temp.elapsed_ms($$ select * from public.search_library_titles('معاشرتی علوم', 100) $$) < 500, 'AC3: and does so in under 500 ms');
select is((select count(*) from public.search_library_titles('978-969-352-601-1')), 1::bigint, 'an ISBN typed with hyphens finds the title');
select is((select count(*) from public.search_library_titles('pakistan stud')), 1::bigint, 'English prefix search works');

-- ── AC4: cover bucket ─────────────────────────────────────────────────────
reset role;
select is((select public from storage.buckets where id = 'library-covers'), false, 'AC4: library-covers is a private bucket');
select ok((select file_size_limit >= 2097152 from storage.buckets where id = 'library-covers'), 'AC4: and accepts a 2 MB cover');
select ok((select allowed_mime_types @> array['image/jpeg', 'image/png'] from storage.buckets where id = 'library-covers'), 'AC4: images only');
select ok(exists (select 1 from pg_policies where schemaname = 'storage' and policyname = 'library_covers_librarian_write'), 'only library staff can upload covers');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_library_title_cover(%L, %L) $$, :'t1', 'other-tenant/x.jpg'), 'FORBIDDEN', 'a cover path must live under the school''s own folder');

-- ── tenant isolation ──────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'librarian', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.library_title), 0::bigint, 'another school sees no titles');

select * from finish();
rollback;
