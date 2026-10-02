-- pgTAP tests for FR-E04: bilingual subject catalogue.
begin;
select plan(7);

select public.provision_tenant('test-subject-co', 'Subject Co', 'owner@subjectco.test');
select id as tenant_id from public.tenant where slug = 'test-subject-co' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller')::text, true);

select public.create_subject('ENGO', 'English Only', '') as engonly_id \gset
select is(
  (select name_ur from public.subject where id = :'engonly_id'),
  'English Only',
  'a blank Urdu name falls back to the English name (English-only subjects are valid)'
);

select public.create_subject('MATH', 'Mathematics', 'ریاضی') as math_id \gset
select is(
  (select name_ur from public.subject where id = :'math_id'),
  'ریاضی',
  'a subject with a proper Urdu name is saved with real Unicode'
);

select public.set_subject_board_code(:'math_id'::uuid, 'FBISE', '054');
select public.set_subject_board_code(:'math_id'::uuid, 'PUNJAB', '07');
select is(
  (select board_code from public.subject_board_code where subject_id = :'math_id' and board = 'FBISE'),
  '054',
  'the FBISE board code for Mathematics is 054'
);
select is(
  (select board_code from public.subject_board_code where subject_id = :'math_id' and board = 'PUNJAB'),
  '07',
  'the Punjab Board code for the same subject is independently 07'
);

-- Re-setting the same board's code updates rather than duplicating.
select public.set_subject_board_code(:'math_id'::uuid, 'FBISE', '054-REV');
select is(
  (select count(*)::int from public.subject_board_code where subject_id = :'math_id' and board = 'FBISE'),
  1,
  'setting a board code twice for the same board updates the one row rather than adding a second'
);

-- is_examinable=false still exists for the timetable, just excluded from
-- mark entry — that exclusion is a mark-entry-grid (Module I) concern, not
-- testable here; this only checks the flag itself persists correctly.
select public.create_subject('PE', 'Physical Education', 'جسمانی تعلیم', 'NON_EXAMINABLE', false) as pe_id \gset
select is(
  (select is_examinable from public.subject where id = :'pe_id'),
  false,
  'a non-examinable subject is still created and simply flagged as such'
);

-- alternate_of_subject_id models the Islamiyat/Ethics relationship (the
-- ALTERNATE_SUBJECT_CONFLICT check itself is an E06 concern, not built yet).
select public.create_subject('ETH', 'Ethics', 'اخلاقیات') as ethics_id \gset
select public.create_subject('ISL', 'Islamiyat', 'اسلامیات', 'CORE', true, null, :'ethics_id'::uuid) as islamiyat_id \gset
select is(
  (select alternate_of_subject_id from public.subject where id = :'islamiyat_id'),
  :'ethics_id',
  'Islamiyat can be declared the alternate of Ethics'
);

select * from finish();
rollback;
