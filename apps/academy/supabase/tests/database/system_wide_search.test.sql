-- pgTAP tests for FR-A20 (system-wide search).
--
-- The authorization tests here are the point of the file. global_search()
-- is SECURITY INVOKER precisely so that RLS is the only gate, and these
-- prove that gate holds for the four ways it could fail: another tenant,
-- another campus, an empty campus claim, and a soft-deleted row.
begin;
select plan(33);

-- ── tenant A ────────────────────────────────────────────────────────────
select public.provision_tenant('search-co', 'Search Co', 'owner@searchco.test');
select id as tenant_id from public.tenant where slug = 'search-co' \gset
select id as gul_id from public.campus where tenant_id = :'tenant_id' \gset

-- ── tenant B: the cross-tenant negative control ─────────────────────────
select public.provision_tenant('rival-co', 'Rival Co', 'owner@rivalco.test');
select id as rival_tenant_id from public.tenant where slug = 'rival-co' \gset
select id as rival_campus_id from public.campus where tenant_id = :'rival_tenant_id' \gset

select gen_random_uuid() as principal_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_user_id', 'principal@searchco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_user_id', :'tenant_id', 'principal', 'Gulberg Principal');

-- ═══ tenant A data, as an owner ═════════════════════════════════════════
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'gul_id'))::text,
  true
);

select public.create_campus('DHA', 'DHA Campus') as dha_id \gset

-- The FR's literal AC1 GR number, reproduced exactly: prefix 'GR-2019',
-- next_value 442, pad 4 → 'GR-2019-0442'.
select public.set_gr_sequence(:'gul_id'::uuid, 'GR-2019', 442::bigint, 4::smallint);

select public.create_student(:'gul_id'::uuid, 'Zainab Tariq', '2015-01-01'::date, 'female',
  p_b_form_no => '42101-9876543-2') as s_zainab \gset
select gr_number as zainab_gr from public.student where id = :'s_zainab'::uuid \gset

select public.create_student(:'gul_id'::uuid, 'Ahmad Ali', '2015-02-01'::date, 'male',
  p_name_ur => 'احمد علی') as s_ahmad \gset
select public.create_student(:'gul_id'::uuid, 'Ahmed Khan', '2015-03-01'::date, 'male') as s_ahmed \gset
-- name_en carries no 'ahmad' at all: this student is reachable from the
-- query 'ahmad' ONLY through the Urdu column's transliteration.
select public.create_student(:'gul_id'::uuid, 'A. Raza', '2015-04-01'::date, 'male',
  p_name_ur => 'احمد رضا') as s_urdu \gset
select public.create_student(:'gul_id'::uuid, 'Deleted Ahmad', '2015-05-01'::date, 'male') as s_deleted \gset

-- Same name, other campus — the AC4 control.
select public.create_student(:'dha_id'::uuid, 'Ahmad Dhanvi', '2015-06-01'::date, 'male') as s_dha \gset

reset role;
insert into public.guardian (tenant_id, cnic, name_en, name_ur, phone_e164)
values (:'tenant_id', '35202-1234567-1', 'Nadia Bibi', 'نادیہ بی بی', '+923001234567')
returning id as g_nadia \gset
set local role authenticated;
select public.link_guardian(:'s_ahmad'::uuid, :'g_nadia'::uuid, 'mother',
  p_is_primary => true, p_receives_billing => true);

select public.create_staff(:'gul_id'::uuid, 'Ahmadullah Sheikh', 'male',
  p_cnic => '42101-5551234-7') as st_ahmad \gset

-- ═══ tenant B data: a name and a CNIC that exist ONLY over there ════════
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'rival_campus_id'))::text,
  true
);
set local role authenticated;
select public.create_student(:'rival_campus_id'::uuid, 'Ahmad Rivalson', '2015-07-01'::date, 'male') as s_rival \gset
reset role;
insert into public.guardian (tenant_id, cnic, name_en, phone_e164)
values (:'rival_tenant_id', '11111-2222222-3', 'Rival Guardian', '+923119998877');
set local role authenticated;

-- Soft-delete one tenant-A student, via the shipped path.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'gul_id'))::text,
  true
);
reset role;
update public.student set deleted_at = now() where id = :'s_deleted'::uuid;
set local role authenticated;


-- ═══════════════════════════════════════════════════════════════════════
-- AC1: 'GR-2019-0442' typed as '2019-0442' puts that student first
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select :'zainab_gr'::text),
  'GR-2019-0442',
  'AC1 setup: the student under test really does carry GR number GR-2019-0442'
);

select is(
  (select entity_id from public.global_search('2019-0442') limit 1),
  :'s_zainab'::uuid,
  'AC1: the query "2019-0442" ranks the GR-2019-0442 student first'
);

select is(
  (select match_field from public.global_search('2019-0442') limit 1),
  'gr_number',
  'AC1: and it is reported as a GR-number match, not a fuzzy name hit'
);

select is(
  (select entity_id from public.global_search('GR-2019-0442') limit 1),
  :'s_zainab'::uuid,
  'AC1: typing the whole GR number finds the same student'
);

select is(
  (select entity_id from public.global_search('42101-9876543-2') limit 1),
  :'s_zainab'::uuid,
  'AC1: the same student is reachable by B-Form number'
);


-- ═══════════════════════════════════════════════════════════════════════
-- AC2: 'ahmad' matches Ahmad, Ahmed and احمد
-- ═══════════════════════════════════════════════════════════════════════

select ok(
  :'s_ahmad'::uuid in (select entity_id from public.global_search('ahmad') where entity_type = 'student'),
  'AC2: "ahmad" returns the student spelled Ahmad'
);

select ok(
  :'s_ahmed'::uuid in (select entity_id from public.global_search('ahmad') where entity_type = 'student'),
  'AC2: "ahmad" returns the student spelled Ahmed (transliteration variance)'
);

select ok(
  :'s_urdu'::uuid in (select entity_id from public.global_search('ahmad') where entity_type = 'student'),
  'AC2: "ahmad" returns the student whose ONLY matching spelling is the Urdu احمد'
);

select is(
  (select match_field from public.global_search('ahmad') where entity_id = :'s_urdu'::uuid),
  'name_ur',
  'AC2: and that hit is attributed to the Urdu column, proving the script bridge fired'
);

select ok(
  :'s_urdu'::uuid in (select entity_id from public.global_search('احمد') where entity_type = 'student'),
  'AC2: a query typed in Urdu also finds the Urdu-spelled student'
);

select ok(
  :'st_ahmad'::uuid in (select entity_id from public.global_search('ahmad') where entity_type = 'staff'),
  'AC2: the same query crosses entity types and reaches a staff member too'
);


-- ═══════════════════════════════════════════════════════════════════════
-- AC3: a CNIC matches whether or not it was typed with dashes
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select entity_id from public.global_search('35202-1234567-1') where entity_type = 'guardian'),
  :'g_nadia'::uuid,
  'AC3: the dashed CNIC form finds the guardian'
);

select is(
  (select entity_id from public.global_search('3520212345671') where entity_type = 'guardian'),
  :'g_nadia'::uuid,
  'AC3: the bare-digits CNIC form finds the same guardian'
);

select is(
  (select entity_id from public.global_search('03001234567') where entity_type = 'guardian'),
  :'g_nadia'::uuid,
  'AC3: a local-format phone number finds the guardian stored as +92…'
);

select is(
  (select entity_id from public.global_search('+92 300 1234567') where entity_type = 'guardian'),
  :'g_nadia'::uuid,
  'AC3: the same number typed with country code and spaces resolves identically'
);


-- ═══════════════════════════════════════════════════════════════════════
-- AC4 + the hard negatives: nothing crosses a tenant or a campus
-- ═══════════════════════════════════════════════════════════════════════

-- A principal scoped to GUL only.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'gul_id'), 'sub', :'principal_user_id')::text,
  true
);

select is(
  (select count(*)::int from public.global_search('Dhanvi')),
  0,
  'AC4: a GUL-scoped principal searching a name that exists only in DHA gets ZERO rows, not a masked one'
);

select ok(
  :'s_dha'::uuid not in (select entity_id from public.global_search('ahmad')),
  'AC4: the DHA student is absent even from a query that matches them, run by a GUL principal'
);

select ok(
  (select count(*) from public.global_search('ahmad')) > 0,
  'AC4: …while that same principal still sees their own campus''s matches (the filter is scope, not a blanket deny)'
);

-- The cross-tenant negative control: tenant A, searching tenant B's data.
select is(
  (select count(*)::int from public.global_search('Rivalson')),
  0,
  'NEGATIVE: a tenant-A user searching a student name that exists only in tenant B gets zero rows'
);

select is(
  (select count(*)::int from public.global_search('11111-2222222-3')),
  0,
  'NEGATIVE: a tenant-A user searching tenant B''s guardian CNIC gets zero rows'
);

select is(
  (select count(*)::int from public.global_search('03119998877')),
  0,
  'NEGATIVE: a tenant-A user searching tenant B''s guardian phone gets zero rows'
);

-- Empty campus claim: `= any('{}')` is false for every campus, so this
-- must be zero rows and never "everything" (the negated-form trap).
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array())::text,
  true
);

select is(
  (select count(*)::int from public.global_search('ahmad')),
  0,
  'NEGATIVE: a principal whose campus_ids claim is empty sees nothing, not everything'
);

-- Soft delete: the row is gone from search the moment deleted_at is set,
-- with no index to re-propagate to.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'gul_id'))::text,
  true
);

select ok(
  :'s_deleted'::uuid not in (select entity_id from public.global_search('ahmad')),
  'NEGATIVE: a soft-deleted student is not searchable, even by an Owner whose policies are otherwise unfiltered'
);

-- Role gate.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', json_build_array(:'gul_id'))::text,
  true
);
select throws_ok(
  $$select * from public.global_search('ahmad')$$,
  '42501',
  'FORBIDDEN',
  'a parent cannot use the staff-facing cross-entity search'
);


-- ═══════════════════════════════════════════════════════════════════════
-- Result cap is disclosed, not silently applied
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'gul_id'))::text,
  true
);

select is(
  (select count(*)::int from public.global_search('ahmad', 2)),
  2,
  'the caller''s limit is honoured exactly'
);

select ok(
  (select bool_and(truncated) from public.global_search('ahmad', 2)),
  'and every returned row carries truncated=true, so the UI can say results were cut rather than lying by omission'
);

select ok(
  (select not bool_or(truncated) from public.global_search('ahmad', 50)),
  'truncated is false when the whole result set fits'
);


-- ═══════════════════════════════════════════════════════════════════════
-- AC5: no sequential scan on student, at 5,000-student scale
-- ═══════════════════════════════════════════════════════════════════════

reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'gul_id', 'BULK-' || lpad(i::text, 6, '0'),
       'Bulk Student ' || i, '2015-01-01'::date, 'male'
  from generate_series(1, 5000) i;
analyze public.student;

create or replace function pg_temp.plan_of(p_sql text)
returns text language plpgsql as $$
declare line text; acc text := '';
begin
  for line in execute 'explain ' || p_sql loop acc := acc || line || E'\n'; end loop;
  return acc;
end;
$$;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'gul_id'))::text,
  true
);

-- The identifier path — what the user story actually describes a front
-- desk typing — is index-driven even with RLS on top, because gr_digits
-- is a stored column compared with texteq (leakproof) rather than an
-- app.digits(...) expression (regexp_replace is not leakproof, and a
-- non-leakproof qual cannot be evaluated before a security qual, which
-- degrades it to a post-filter).
select ok(
  pg_temp.plan_of(format(
    'select id from public.student where tenant_id = %L and gr_digits = %L',
    :'tenant_id', '20190442'
  )) not like '%Seq Scan on student%',
  'AC5: the GR-number lookup index-scans under RLS at 5,000 students — no sequential scan on student'
);

-- idx_student_bform_digits is partial (where b_form_no is not null), so
-- the is-not-null predicate is what makes it reachable — which is exactly
-- how the function's B-Form branch is written.
select ok(
  pg_temp.plan_of(format(
    'select id from public.student where tenant_id = %L and b_form_no is not null and bform_digits = %L',
    :'tenant_id', '4210198765432'
  )) not like '%Seq Scan on student%',
  'AC5: the B-Form lookup likewise index-scans under RLS'
);

-- Both pg_trgm word-similarity operators are non-leakproof, so no trigram
-- index is reachable underneath RLS at all — the fuzzy-name branch scans,
-- and AC5 cannot be met for it without abandoning RLS.
--
-- What is still worth pinning is that the branch stays in the OPERATOR
-- form. Operand order is free (<% and %> are commutators, the planner
-- swaps them), but rewriting it as word_similarity(q, name_en) > 0.3 —
-- FR-D19's spelling — forfeits the index permanently, RLS or no RLS.
-- Asserted with enable_seqscan off so this tests INDEXABILITY and not the
-- planner's cost estimate, which would make it flap with table statistics.
reset role;
set local enable_seqscan = off;

select ok(
  pg_temp.plan_of(
    $$select id from public.student where name_en operator(public.%>) 'ahmad'$$
  ) like '%idx_student_name_trgm%',
  'AC5: the operator form (name_en %> q) can be answered from the trigram GIN index'
);

select ok(
  pg_temp.plan_of(
    $$select id from public.student where public.word_similarity('ahmad', name_en) > 0.3$$
  ) like '%Seq Scan on student%',
  'AC5 (control): the equivalent word_similarity() function form cannot use that index at any cost setting — which is why the branch is written as an operator'
);

set local enable_seqscan = on;
set local role authenticated;

-- 3-arg form: pgTAP's 4-arg has_index() reads the 4th argument as a column
-- list, not a description.
select has_index('public'::name, 'student'::name, 'idx_student_name_ur_roman_trgm'::name);


-- ═══════════════════════════════════════════════════════════════════════
-- Regression guard on the design decision itself
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select prosecdef from pg_proc where oid = 'public.global_search(text, int)'::regprocedure),
  false,
  'global_search stays SECURITY INVOKER: flipping it to DEFINER would silently drop every RLS filter this file just proved'
);

select finish();
rollback;
