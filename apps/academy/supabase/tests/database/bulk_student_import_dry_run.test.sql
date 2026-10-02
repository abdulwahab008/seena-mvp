-- pgTAP tests for FR-C14: validate a bulk student import as a dry run.
--
-- Scale note: the AC's 5,000-row / 118-blocked file is illustrative
-- scale, not a literal row count to test at — the counting, chunking and
-- whole-batch duplicate logic is identical at 12 rows, and the 5,000-row
-- shape is exercised in lib/student-import.test.ts where it costs
-- milliseconds instead of a minute of pgTAP.
--
-- The file is staged in TWO chunks on purpose: the duplicate GR pair
-- (rows 5 and 8) straddles the chunk boundary, which is the case
-- stage_import_rows() structurally cannot catch and
-- finalise_import_batch()'s whole-batch sweep exists for.
--
-- What is checked here is the register-state half of validation (the
-- class exists in THIS tenant, the GR is already on the register — even
-- for a soft-deleted student, the B-Form already belongs to someone),
-- the whole-batch duplicate sweep, the error-merge rule, the counting
-- convention, role/campus gating, RLS scoping, and the single most
-- important claim of the whole FR: zero rows land in public.student.
-- The file-shaped half (header set, formats, class-name resolution) lives
-- in lib/student-import.ts and is covered by its own vitest suite.
begin;
select plan(40);

select public.provision_tenant('test-import-co', 'Import Co', 'owner@importco.test');
select id as tenant_id from public.tenant where slug = 'test-import-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-import-other-co', 'Import Other Co', 'owner@importotherco.test');
select id as other_tenant_id from public.tenant where slug = 'test-import-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset
select id as other_session_id from public.academic_session where tenant_id = :'other_tenant_id' \gset
select id as other_class_id from public.class_level where tenant_id = :'other_tenant_id' and code = '1' \gset

-- A second campus in the same tenant: tenant isolation and campus
-- scoping are different guards, and a same-tenant/other-campus principal
-- is the only caller that tells them apart.
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Import Campus 2', 'IC2') returning id as campus2_id \gset

-- Readability helper for the per-row assertions below. Created as
-- postgres, before the role switch; it is SECURITY INVOKER, so it still
-- reads import_row under the caller's own RLS.
create function pg_temp.row_codes(p_batch uuid, p_row int)
returns text[]
language sql
stable
as $$
  select array_agg(e ->> 'code' order by e ->> 'code')
    from public.import_row r, lateral jsonb_array_elements(r.errors) as e
   where r.batch_id = p_batch and r.row_no = p_row;
$$;

create function pg_temp.row_messages(p_batch uuid, p_row int, p_column text)
returns text[]
language sql
stable
as $$
  select array_agg(e ->> 'message')
    from public.import_row r, lateral jsonb_array_elements(r.errors) as e
   where r.batch_id = p_batch and r.row_no = p_row and e ->> 'column' = p_column;
$$;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- ── the register the file is validated against ─────────────────────────

select public.create_student(:'campus_id'::uuid, 'Existing One', '2015-01-01'::date, 'male', p_b_form_no => '4210199999998') as existing_id \gset
select gr_number as existing_gr from public.student where id = :'existing_id' \gset

-- FR-A15: a soft-deleted student's GR number stays taken.
select public.create_student(:'campus_id'::uuid, 'Deleted One', '2015-01-01'::date, 'male') as deleted_id \gset
select gr_number as deleted_gr from public.student where id = :'deleted_id' \gset
select public.soft_delete('student', :'deleted_id'::uuid);

select count(*)::int as students_before from public.student where tenant_id = :'tenant_id' \gset

-- ── create_import_batch ────────────────────────────────────────────────

select public.create_import_batch(:'campus_id'::uuid, :'session_id'::uuid, 'register.csv') as batch_json \gset
select ((:'batch_json')::jsonb ->> 'batch_id') as batch_id \gset

select is(
  ((:'batch_json')::jsonb ->> 'file_path'),
  :'tenant_id' || '/' || :'batch_id' || '/source.csv',
  'the batch reserves a tenant- and batch-scoped object path before anything is uploaded'
);

select is(
  (select status::text || ':' || dry_run::text from public.import_batch where id = :'batch_id'::uuid),
  'validating:true',
  'a new batch opens as a validating dry run'
);

-- ── chunk 1: rows 2-5 ──────────────────────────────────────────────────
-- row 2 clean; row 3 missing B-Form (client warning); row 4 a GR already
-- on the register; row 5 the first half of a cross-chunk duplicate GR.

select is(
  public.stage_import_rows(:'batch_id'::uuid, jsonb_build_array(
    jsonb_build_object(
      'row_no', 2,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Clean One', 'dob', '2016-01-01', 'gender', 'female',
                                       'class_level_id', :'class1_id', 'b_form_no', '42101-0000001-1'),
      'errors', '[]'::jsonb
    ),
    jsonb_build_object(
      'row_no', 3,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'No Bform', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id'),
      'errors', jsonb_build_array(jsonb_build_object(
        'column', 'b_form_no', 'code', 'BFORM_MISSING', 'severity', 'warning',
        'message', 'No B-Form number - the student can still be imported, but it is required before board registration.'))
    ),
    jsonb_build_object(
      'row_no', 4,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Gr Clash', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'gr_number', :'existing_gr'),
      'errors', '[]'::jsonb
    ),
    jsonb_build_object(
      'row_no', 5,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Dup A', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'gr_number', 'PAPER-0042'),
      'errors', '[]'::jsonb
    )
  )),
  4,
  'the first 500-row chunk stages its rows'
);

-- ── chunk 2: rows 6-13 ─────────────────────────────────────────────────

select is(
  public.stage_import_rows(:'batch_id'::uuid, jsonb_build_array(
    -- row 6: the GR of a SOFT-DELETED student — still taken.
    jsonb_build_object(
      'row_no', 6,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Deleted Clash', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'gr_number', :'deleted_gr'),
      'errors', '[]'::jsonb
    ),
    -- row 7: a B-Form already on the register.
    jsonb_build_object(
      'row_no', 7,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Bform Clash', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'b_form_no', '42101-9999999-8'),
      'errors', '[]'::jsonb
    ),
    -- row 8: the other half of the cross-chunk duplicate GR.
    jsonb_build_object(
      'row_no', 8,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Dup B', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'gr_number', 'PAPER-0042'),
      'errors', '[]'::jsonb
    ),
    -- row 9: a real class id, but another tenant's.
    jsonb_build_object(
      'row_no', 9,
      'raw', jsonb_build_object('class', 'Class 1'),
      'normalised', jsonb_build_object('name_en', 'Foreign Class', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'other_class_id'),
      'errors', '[]'::jsonb
    ),
    -- row 10: a class id that is not even a uuid — must be reported, not
    -- abort the whole chunk with 22P02.
    jsonb_build_object(
      'row_no', 10,
      'raw', jsonb_build_object('class', 'Class One'),
      'normalised', jsonb_build_object('name_en', 'Junk Class', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', 'not-a-uuid'),
      'errors', '[]'::jsonb
    ),
    -- row 11: the client already reported the class; the server must not
    -- say the same thing twice about the same cell.
    jsonb_build_object(
      'row_no', 11,
      'raw', jsonb_build_object('class', 'Class One'),
      'normalised', jsonb_build_object('name_en', 'Already Flagged', 'dob', '2016-01-01', 'gender', 'male'),
      'errors', jsonb_build_array(jsonb_build_object(
        'column', 'class', 'code', 'UNKNOWN_CLASS', 'severity', 'error',
        'message', 'Unknown class ''Class One'' - expected one of NUR, KG, 1..12'))
    ),
    -- rows 12/13: an in-file duplicate the client already caught; the
    -- whole-batch sweep must not re-report it.
    jsonb_build_object(
      'row_no', 12,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Dup C', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'gr_number', 'PAPER-0099'),
      'errors', jsonb_build_array(jsonb_build_object(
        'column', 'gr_number', 'code', 'DUPLICATE_IN_FILE', 'severity', 'error', 'message', 'reported by the file layer'))
    ),
    jsonb_build_object(
      'row_no', 13,
      'raw', jsonb_build_object('class', '1'),
      'normalised', jsonb_build_object('name_en', 'Dup D', 'dob', '2016-01-01', 'gender', 'male',
                                       'class_level_id', :'class1_id', 'gr_number', 'PAPER-0099'),
      'errors', jsonb_build_array(jsonb_build_object(
        'column', 'gr_number', 'code', 'DUPLICATE_IN_FILE', 'severity', 'error', 'message', 'reported by the file layer'))
    )
  )),
  8,
  'the second chunk stages its rows'
);

-- ── finalise ───────────────────────────────────────────────────────────

select public.finalise_import_batch(:'batch_id'::uuid) as summary \gset

select is(((:'summary')::jsonb ->> 'total_rows')::int, 12, 'the summary counts every staged row');
select is(((:'summary')::jsonb ->> 'error_rows')::int, 10, 'AC: blocked rows are counted');
select is(((:'summary')::jsonb ->> 'ok_rows')::int, 2, 'AC: ready rows are counted, and ready + blocked = total');
select is(((:'summary')::jsonb ->> 'warning_rows')::int, 1, 'a warning row is counted as ready, and separately as carrying a warning');
select is(((:'summary')::jsonb ->> 'status'), 'validated', 'the batch closes as validated');

select is(pg_temp.row_codes(:'batch_id'::uuid, 2), null, 'a clean row carries no issues at all');
select is(
  (select severity::text from public.import_row where batch_id = :'batch_id'::uuid and row_no = 2),
  'ok',
  'a clean row is severity ok'
);

-- AC: a missing B-Form number is a WARNING and the row stays importable.
select is(pg_temp.row_codes(:'batch_id'::uuid, 3), array['BFORM_MISSING'], 'a missing B-Form is reported as its own issue');
select is(
  (select severity::text from public.import_row where batch_id = :'batch_id'::uuid and row_no = 3),
  'warning',
  'AC: a missing B-Form leaves the row importable, not blocked'
);

select is(pg_temp.row_codes(:'batch_id'::uuid, 4), array['GR_IN_USE'], 'a GR number already on the register blocks the row');
select is(
  pg_temp.row_codes(:'batch_id'::uuid, 6),
  array['GR_IN_USE'],
  'FR-A15: a SOFT-DELETED student''s GR number still counts as taken'
);
select is(pg_temp.row_codes(:'batch_id'::uuid, 7), array['BFORM_IN_USE'], 'a B-Form already on the register blocks the row');

-- AC: class names that do not match configured classes block the row.
select is(
  pg_temp.row_codes(:'batch_id'::uuid, 9),
  array['UNKNOWN_CLASS'],
  'a class belonging to another tenant is not a configured class here'
);
select is(
  pg_temp.row_codes(:'batch_id'::uuid, 10),
  array['UNKNOWN_CLASS'],
  'a malformed class id is reported as an unknown class, not a chunk-wide cast failure'
);

-- AC: the same GR number twice WITHIN the file blocks BOTH occurrences.
select is(pg_temp.row_codes(:'batch_id'::uuid, 5), array['DUPLICATE_IN_FILE'], 'AC: the FIRST occurrence of a duplicate GR is blocked');
select is(pg_temp.row_codes(:'batch_id'::uuid, 8), array['DUPLICATE_IN_FILE'], 'AC: the second occurrence is blocked too');
select is(
  pg_temp.row_messages(:'batch_id'::uuid, 5, 'gr_number'),
  array['GR number ''PAPER-0042'' appears more than once in this file (rows 5, 8) - every occurrence is blocked.'],
  'the duplicate message names every row the number appears on, across the chunk boundary'
);

select is(
  pg_temp.row_messages(:'batch_id'::uuid, 11, 'class'),
  array['Unknown class ''Class One'' - expected one of NUR, KG, 1..12'],
  'the server does not restate a cell the file layer already reported'
);
select is(
  pg_temp.row_messages(:'batch_id'::uuid, 12, 'gr_number'),
  array['reported by the file layer'],
  'the whole-batch duplicate sweep leaves a duplicate the file layer already caught alone'
);

-- ── the point of the whole FR ──────────────────────────────────────────

select is(
  (select count(*)::int from public.student where tenant_id = :'tenant_id'),
  (:'students_before')::int,
  'AC: a dry run creates ZERO students - the register is exactly as it was'
);
select is(
  (select count(*)::int from public.student where tenant_id = :'tenant_id' and name_en in ('Clean One', 'No Bform', 'Dup A')),
  0,
  'AC: not even the rows that would have imported cleanly exist in the student table'
);
select is(
  (select count(*)::int from public.gr_ledger where gr_number in ('PAPER-0042', 'PAPER-0099')),
  0,
  'a dry run does not reserve GR numbers either - allocation is FR-C15''s job'
);

-- ── a finalised batch is closed ────────────────────────────────────────

select throws_ok(
  format($$select public.stage_import_rows(%L::uuid, '[]'::jsonb)$$, :'batch_id'),
  'IMPORT_BATCH_NOT_OPEN',
  'no further rows can be staged into a finalised batch'
);
select throws_ok(
  format($$select public.finalise_import_batch(%L::uuid)$$, :'batch_id'),
  'IMPORT_BATCH_NOT_OPEN',
  'a batch cannot be finalised twice'
);

-- ── scope and role gating ──────────────────────────────────────────────

select throws_ok(
  format($$select public.create_import_batch(%L::uuid, %L::uuid, 'x.csv')$$, :'campus_id', :'other_session_id'),
  'SESSION_NOT_FOUND',
  'a session from another tenant cannot be imported into'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select throws_ok(
  format($$select public.create_import_batch(%L::uuid, %L::uuid, 'x.csv')$$, :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a teacher cannot start a bulk student import'
);
select is(
  (select count(*)::int from public.import_batch where id = :'batch_id'::uuid),
  0,
  'a teacher on the same campus cannot read the batch either - import_row.raw is a spreadsheet full of unadmitted children'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus2_id'))::text,
  true
);
select throws_ok(
  format($$select public.create_import_batch(%L::uuid, %L::uuid, 'x.csv')$$, :'campus_id', :'session_id'),
  'FORBIDDEN',
  'a principal cannot start an import for a campus outside their own scope'
);
select is(
  (select count(*)::int from public.import_batch where id = :'batch_id'::uuid),
  0,
  'import_batch_campus_scope hides another campus'' batch from a campus-scoped principal'
);
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_id'::uuid),
  0,
  'import_row_read_owner_of_batch hides its rows too'
);
select throws_ok(
  format($$select public.stage_import_rows(%L::uuid, '[]'::jsonb)$$, :'batch_id'),
  'FORBIDDEN',
  'a campus-scoped principal cannot stage rows into another campus'' batch'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.import_batch where id = :'batch_id'::uuid),
  1,
  'a principal scoped to the batch''s own campus sees it'
);
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_id'::uuid),
  12,
  'and sees every one of its rows'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select is(
  (select count(*)::int from public.import_batch where id = :'batch_id'::uuid),
  0,
  'another tenant''s owner sees no batch at all'
);
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_id'::uuid),
  0,
  'and none of its rows'
);

reset role;
select is(
  (select b.public::text from storage.buckets b where b.id = 'imports'),
  'false',
  'the imports bucket is private'
);

select * from finish();
rollback;
