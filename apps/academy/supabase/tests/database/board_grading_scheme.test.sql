-- pgTAP tests for FR-J01: board grading scheme configuration.
--
--   AC1  The published FBISE set (A1 80-100 ... F 0-32.99) saves, validates
--        and activates, and it resolves for Class 9 through Class 12.
--   AC2  Bands 70-79 beside 80-100 are refused naming 79.00-80.00, and so is
--        every other way to leave 0.00-100.00 uncovered or doubly covered.
--   AC3  A Cambridge scheme (A*, A, B, C, D, E, U) sits beside the FBISE one
--        and a section tagged Cambridge resolves to it, with no code change.
--   AC4  An activated scheme's bands are frozen for every role including the
--        table owner; new_grading_scheme_version() carries them into a new
--        effective-dated draft, and a date before that date still resolves
--        to the old version.
--
-- Plus the property FR-J02 rides on and no acceptance criterion states:
-- grade-boundary determinism. 32.995% grades as 33.00% — the number a report
-- card prints — on every run, on every machine.
begin;
select plan(50);

select public.provision_tenant('test-grading-co', 'Grading Co', 'owner@grading.test');
select id as tenant_id from public.tenant where slug = 'test-grading-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-grading-rival', 'Rival Co', 'owner@rival.test');
select id as rival_id from public.tenant where slug = 'test-grading-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@grading.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Grading Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@grading.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Farah Siddiqui');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'teacher@grading.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Not The Exam Office');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@rival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

select id as class9  from public.class_level where tenant_id = :'tenant_id' and code = '9'  \gset
select id as class12 from public.class_level where tenant_id = :'tenant_id' and code = '12' \gset

-- Structure first, as the Principal-or-above who owns it. Class 9 sits two
-- sections: an ordinary one and an O-Level one tagged Cambridge (AC3).
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.create_section(:'campus_a', :'session_a', :'class9',  'A', 40) as sec9  \gset
select public.create_section(:'campus_a', :'session_a', :'class12', 'A', 40) as sec12 \gset
select public.create_stream('CIE9', 'Cambridge', 'کیمبرج', 'CAMBRIDGE'::public.board, 10::smallint) as cie_stream \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'O', 30) as sec9_cie \gset
select public.set_section_stream(:'sec9_cie', :'cie_stream') as _s1 \gset

-- Everything below is the Exam Controller's — a grade scale is the exam
-- office's to define.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the published FBISE set
-- ═══════════════════════════════════════════════════════════════════════

select public.save_grading_scheme(
  'FBISE'::public.board, 'FBISE 2025', date '2025-04-01',
  '[{"grade_label":"A1","min_pct":80,"max_pct":100,"gpa_point":4.00,"remark_en":"Outstanding","remark_ur":"نمایاں"},
    {"grade_label":"A", "min_pct":70,"max_pct":79.99,"gpa_point":3.70,"remark_en":"Excellent"},
    {"grade_label":"B", "min_pct":60,"max_pct":69.99,"gpa_point":3.30,"remark_en":"Very good"},
    {"grade_label":"C", "min_pct":50,"max_pct":59.99,"gpa_point":3.00,"remark_en":"Good"},
    {"grade_label":"D", "min_pct":40,"max_pct":49.99,"gpa_point":2.50,"remark_en":"Fair"},
    {"grade_label":"E", "min_pct":33,"max_pct":39.99,"gpa_point":2.00,"remark_en":"Satisfactory"},
    {"grade_label":"F", "min_pct":0, "max_pct":32.99,"gpa_point":0.00,"is_pass":false,"remark_en":"Fail"}]'::jsonb
) as fbise \gset

select is(
  (select count(*)::int from public.grading_band where scheme_id = :'fbise'),
  7,
  'AC1: the seven published FBISE bands are stored — adjacent bounds 32.99/33.00 coexist under the exclusion'
);

select ok(
  public.fn_validate_grading_bands(:'fbise'),
  'AC1: validation passes on a set that covers 0.00-100.00 exactly once'
);

select is(
  (select grade_label from public.grading_band where scheme_id = :'fbise' and sequence = 1),
  'A1',
  'AC1: bands are sequenced from the highest down, the way a board prints its table'
);

select is(
  (select status::text from public.grading_scheme where id = :'fbise'),
  'draft',
  'a saved scheme starts as a draft and is not resolvable yet'
);

select public.activate_grading_scheme(:'fbise') as _act \gset
select is(
  (select status::text from public.grading_scheme where id = :'fbise'),
  'active',
  'AC1: activation is what makes a validated scheme assignable'
);

-- "assignable to classes 9 to 12": both resolve to it, because a scheme is
-- per board and both classes sit FBISE.
select is(
  public.fn_grading_scheme_for_section(:'sec9', date '2025-09-01'),
  :'fbise'::uuid,
  'AC1: Class 9 resolves to the FBISE scheme'
);
select is(
  public.fn_grading_scheme_for_section(:'sec12', date '2025-09-01'),
  :'fbise'::uuid,
  'AC1: Class 12 resolves to the same scheme — one scale, every class on that board'
);

select ok(
  public.fn_grading_scheme_for_section(:'sec9', date '2025-03-31') is null,
  'a date before effective_from resolves to no scheme rather than to the nearest one'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: a gap is refused, and the refusal names it
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Gapped', date '2025-04-01',
    '[{"grade_label":"A1","min_pct":80,"max_pct":100},
      {"grade_label":"A","min_pct":70,"max_pct":79},
      {"grade_label":"F","min_pct":0,"max_pct":69.99}]'::jsonb)$$,
  '23514',
  'grading bands leave 79.00-80.00 uncovered',
  'AC2: bands 70-79 beside 80-100 are refused naming the uncovered range'
);

select is(
  (select count(*)::int from public.grading_scheme where tenant_id = :'tenant_id' and board = 'PUNJAB'),
  0,
  'AC2: the refusal wrote nothing — no half-applied scheme is left behind'
);

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Overlapping', date '2025-04-01',
    '[{"grade_label":"A1","min_pct":80,"max_pct":100},
      {"grade_label":"A","min_pct":70,"max_pct":80},
      {"grade_label":"F","min_pct":0,"max_pct":69.99}]'::jsonb)$$,
  '23514',
  'grading bands A and A1 overlap between 80.00 and 80.00',
  'AC2: an overlap is refused naming both bands and the range they share'
);

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Floor missing', date '2025-04-01',
    '[{"grade_label":"A1","min_pct":80,"max_pct":100},
      {"grade_label":"F","min_pct":33,"max_pct":79.99}]'::jsonb)$$,
  '23514',
  'grading bands leave 0.00-33.00 uncovered',
  'AC2: a scheme that never reaches 0.00 is refused naming the floor it leaves open'
);

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Ceiling missing', date '2025-04-01',
    '[{"grade_label":"A1","min_pct":80,"max_pct":99},
      {"grade_label":"F","min_pct":0,"max_pct":79.99}]'::jsonb)$$,
  '23514',
  'grading bands leave 99.00-100.00 uncovered',
  'AC2: a scheme that stops short of 100.00 is refused naming the ceiling'
);

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Empty', date '2025-04-01', '[]'::jsonb)$$,
  '23514',
  'a grading scheme needs at least one band',
  'a scheme with no bands is not a scale'
);

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Too precise', date '2025-04-01',
    '[{"grade_label":"A1","min_pct":79.995,"max_pct":100},
      {"grade_label":"F","min_pct":0,"max_pct":79.994}]'::jsonb)$$,
  '23514',
  'band A1 bounds must have at most two decimal places',
  'a third decimal place is refused rather than silently rounded into storage'
);

select throws_ok(
  $$select public.save_grading_scheme('PUNJAB'::public.board, 'Same label twice', date '2025-04-01',
    '[{"grade_label":"A","min_pct":80,"max_pct":100},
      {"grade_label":"A","min_pct":0,"max_pct":79.99}]'::jsonb)$$,
  '23514',
  NULL,
  'two bands of one scheme cannot carry the same grade label'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Grade-boundary determinism (what FR-J02 rides on)
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (public.fn_grade_for_percentage(:'fbise', 32.995)).grade_label,
  'E',
  'exactly 32.995 rounds to 33.00 and grades as E — the number the report card prints'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 32.994)).grade_label,
  'F',
  '32.994 rounds to 32.99 and grades as F — the boundary is decided once, on the printed value'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 33.00)).grade_label,
  'E',
  '33.00 exactly is the bottom of E, not the top of F'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 79.99)).grade_label,
  'A',
  '79.99 is the top of A'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 80.00)).grade_label,
  'A1',
  '80.00 is the bottom of A1'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 100.00)).grade_label,
  'A1',
  '100.00 is inside the top band, not past it'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 0.00)).grade_label,
  'F',
  '0.00 is inside the bottom band'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 75.294117647)).grade_label,
  'A',
  'a raw division result grades on its two-decimal rounding'
);
select ok(
  (public.fn_grade_for_percentage(:'fbise', null::numeric)).grade_label is null,
  'a null percentage has no grade — a fully exempt subject is not an F'
);
select is(
  (public.fn_grade_for_percentage(:'fbise', 32.99)).is_pass,
  false,
  'the scheme itself says F is not a pass — FR-J02 reads it rather than hardcoding a label'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: Cambridge beside FBISE, resolved from the section's tag
-- ═══════════════════════════════════════════════════════════════════════

select public.save_grading_scheme(
  'CAMBRIDGE'::public.board, 'Cambridge IGCSE', date '2025-04-01',
  '[{"grade_label":"A*","min_pct":90,"max_pct":100,"gpa_point":4.00},
    {"grade_label":"A", "min_pct":80,"max_pct":89.99,"gpa_point":4.00},
    {"grade_label":"B", "min_pct":70,"max_pct":79.99,"gpa_point":3.00},
    {"grade_label":"C", "min_pct":60,"max_pct":69.99,"gpa_point":2.00},
    {"grade_label":"D", "min_pct":50,"max_pct":59.99,"gpa_point":1.00},
    {"grade_label":"E", "min_pct":40,"max_pct":49.99,"gpa_point":0.00},
    {"grade_label":"U", "min_pct":0, "max_pct":39.99,"is_pass":false}]'::jsonb
) as cie \gset
select public.activate_grading_scheme(:'cie') as _act2 \gset

select ok(
  (select gpa_point from public.grading_band where scheme_id = :'cie' and grade_label = 'U') is null,
  'AC3: Cambridge U is ungraded — no GPA point, rather than a zero that would average in'
);

select is(
  public.fn_grading_scheme_for_section(:'sec9_cie', date '2025-09-01'),
  :'cie'::uuid,
  'AC3: a class tagged Cambridge resolves to the Cambridge scheme'
);
select is(
  public.fn_grading_scheme_for_section(:'sec9', date '2025-09-01'),
  :'fbise'::uuid,
  'AC3: the FBISE section beside it still resolves to FBISE — both schemes coexist'
);
select is(
  (public.fn_grade_for_percentage(
     public.fn_grading_scheme_for_section(:'sec9_cie', date '2025-09-01'), 85.00)).grade_label,
  'A',
  'AC3: 85% is an A at Cambridge, resolved from the section tag with no code change'
);
select is(
  (public.fn_grade_for_percentage(
     public.fn_grading_scheme_for_section(:'sec9', date '2025-09-01'), 85.00)).grade_label,
  'A1',
  'AC3: the same 85% on the FBISE section beside it is an A1'
);

select is(
  app.fn_board_for_section(:'sec9')::text,
  'FBISE',
  'a section with no stream falls back to the campus board, and FBISE is the federal default'
);
select public.set_campus_board(:'campus_a', 'PUNJAB'::public.board) as _cb \gset
select is(
  app.fn_board_for_section(:'sec9')::text,
  'PUNJAB',
  'the campus board is a campus_setting, so a Punjab Board campus needs no code change either'
);
select is(
  app.fn_board_for_section(:'sec9_cie')::text,
  'CAMBRIDGE',
  'the section''s stream still wins over the campus board'
);
select public.set_campus_board(:'campus_a', 'FBISE'::public.board) as _cb2 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: an active scale does not move, and old results keep their version
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$select public.save_grading_scheme('FBISE'::public.board, 'FBISE 2025', date '2025-04-01',
    '[{"grade_label":"A1","min_pct":85,"max_pct":100},
      {"grade_label":"F","min_pct":0,"max_pct":84.99}]'::jsonb, %L)$$, :'fbise'),
  '42501',
  'grading scheme is in use — create a new effective-dated version to change a band',
  'AC4: editing an activated scheme''s bands is refused, and the refusal points at versioning'
);

select throws_ok(
  format($$update public.grading_band set min_pct = 85.00
            where scheme_id = %L and grade_label = 'A1'$$, :'fbise'),
  '42501',
  'grading scheme is in use — create a new effective-dated version to change a band',
  'AC4: a direct UPDATE on an active band is refused too — the freeze is a trigger, not a policy'
);

select throws_ok(
  format($$update public.grading_scheme set effective_from = date '2024-04-01' where id = %L$$, :'fbise'),
  '42501',
  'grading scheme is in use — create a new effective-dated version to change it',
  'AC4: an active scheme''s effective date cannot move under the results that resolved against it'
);

-- The freeze binds the table owner too, not just the roles a policy names.
reset role;
select throws_ok(
  format($$insert into public.grading_band (tenant_id, scheme_id, min_pct, max_pct, grade_label, sequence)
           values (%L, %L, 75.00, 85.00, 'X', 99)$$, :'tenant_id', :'fbise'),
  '42501',
  'grading scheme is in use — create a new effective-dated version to change a band',
  'AC4: a raw insert into an active scheme by the table owner is refused'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.new_grading_scheme_version(:'fbise', date '2026-04-01') as fbise2 \gset

select is(
  (select version from public.grading_scheme where id = :'fbise2'),
  2,
  'AC4: a new effective-dated version is created'
);
select is(
  (select count(*)::int from public.grading_band where scheme_id = :'fbise2'),
  7,
  'AC4: the new version starts from the old version''s bands rather than from nothing'
);

-- The EXCLUDE constraint still holds on the new draft, for every writer.
reset role;
select throws_ok(
  format($$insert into public.grading_band (tenant_id, scheme_id, min_pct, max_pct, grade_label, sequence)
           values (%L, %L, 50.00, 60.00, 'X', 99)$$, :'tenant_id', :'fbise2'),
  '23P01',
  NULL,
  'AC2: EXCLUDE USING gist refuses an overlapping band on a draft, whoever writes it'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

-- Move the boundary that prompted the version, then activate it.
select public.save_grading_scheme(
  'FBISE'::public.board, 'FBISE 2026', date '2026-04-01',
  '[{"grade_label":"A1","min_pct":85,"max_pct":100,"gpa_point":4.00},
    {"grade_label":"A", "min_pct":70,"max_pct":84.99,"gpa_point":3.70},
    {"grade_label":"F", "min_pct":0, "max_pct":69.99,"gpa_point":0.00,"is_pass":false}]'::jsonb,
  :'fbise2'
) as _v2 \gset
select public.activate_grading_scheme(:'fbise2') as _act3 \gset

select is(
  public.fn_grading_scheme_for_section(:'sec9', date '2025-09-01'),
  :'fbise'::uuid,
  'AC4: a 2025 result still resolves to v1 — prior results keep resolving to the old version'
);
select is(
  (public.fn_grade_for_percentage(
     public.fn_grading_scheme_for_section(:'sec9', date '2025-09-01'), 82.00)).grade_label,
  'A1',
  'AC4: 82% in 2025 is still an A1 on the scale that was published then'
);
select is(
  public.fn_grading_scheme_for_section(:'sec9', date '2026-09-01'),
  :'fbise2'::uuid,
  'AC4: a 2026 result resolves to v2'
);
select is(
  (public.fn_grade_for_percentage(
     public.fn_grading_scheme_for_section(:'sec9', date '2026-09-01'), 82.00)).grade_label,
  'A',
  'AC4: the same 82% is an A under v2 — the edit applies forward only'
);

select throws_ok(
  format($$select public.new_grading_scheme_version(%L, date '2025-01-01')$$, :'fbise'),
  '23514',
  NULL,
  'a new version cannot start before the version it replaces'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Who may configure a scale, and who may read one
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  $$select public.save_grading_scheme('KPK'::public.board, 'Teacher scheme', date '2025-04-01',
    '[{"grade_label":"P","min_pct":0,"max_pct":100}]'::jsonb)$$,
  '42501',
  NULL,
  'a subject teacher cannot define a board grade scale'
);
select is(
  (select count(*)::int from public.grading_scheme),
  3,
  'a teacher still reads the scales their school grades on — a report card prints the band remark'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(gen_random_uuid()), 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.grading_scheme),
  0,
  'grading_scheme_tenant_scope: another school sees none of these scales'
);
select is(
  (select count(*)::int from public.grading_band),
  0,
  'and none of their bands'
);

select * from finish();
rollback;
