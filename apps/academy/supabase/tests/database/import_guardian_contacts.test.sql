-- pgTAP tests for import_guardian_contacts: bulk-linking fathers to students already on the register.
begin;
select plan(17);

select public.provision_tenant('test-guardian-import', 'Guardian Import Co', 'owner@guardianimport.test');
select id as tenant_id from public.tenant where slug = 'test-guardian-import' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'GB', 'Guardian Campus B') returning id as campus_b \gset

insert into public.student (tenant_id, campus_id, gr_number, name_en, father_name_en, dob, gender) values
  (:'tenant_id', :'campus_id', 'GI-1', 'Elder Sibling', 'Tariq Mehmood', '2012-01-01', 'male'),
  (:'tenant_id', :'campus_id', 'GI-2', 'Younger Sibling', 'Tariq Mehmood', '2015-01-01', 'female'),
  (:'tenant_id', :'campus_id', 'GI-3', 'Phone Only', 'Asif Ali', '2013-01-01', 'male'),
  (:'tenant_id', :'campus_id', 'GI-4', 'Bad Cnic', 'Nadeem', '2013-01-01', 'male'),
  (:'tenant_id', :'campus_b', 'GI-5', 'Other Campus', 'Rashid', '2013-01-01', 'male');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner')::text, true);

select public.import_guardian_contacts('[
  {"row": 2, "gr_number": "GI-1", "father_cnic": "35202-1234567-1", "father_phone": "0300 1234567"},
  {"row": 3, "gr_number": "GI-2", "father_cnic": "3520212345671"},
  {"row": 4, "gr_number": "GI-3", "father_phone": "+92 321 7654321"},
  {"row": 5, "gr_number": "GI-4", "father_cnic": "123"},
  {"row": 6, "gr_number": "NOPE-9", "father_cnic": "35202-7777777-7"},
  {"row": 7, "gr_number": "GI-1", "father_cnic": "35202-1234567-1"}
]'::jsonb) as r \gset

select is((:'r'::jsonb ->> 'linked')::int, 3, 'three rows link a father');
select is((:'r'::jsonb ->> 'failed')::int, 3, 'three rows fail on their own without stopping the rest');

select is((select count(distinct sg.guardian_id)::int from public.student_guardian sg join public.student s on s.id = sg.student_id where s.gr_number in ('GI-1', 'GI-2')), 1,
  'siblings with the same CNIC (with or without dashes) share one guardian record');
select is((select cnic from public.guardian g join public.student_guardian sg on sg.guardian_id = g.id join public.student s on s.id = sg.student_id where s.gr_number = 'GI-1'), '35202-1234567-1',
  'the CNIC is stored in the standard dashed form');
select is((select phone_e164 from public.guardian g join public.student_guardian sg on sg.guardian_id = g.id join public.student s on s.id = sg.student_id where s.gr_number = 'GI-1'), '+923001234567',
  'a local 03xx number is stored as +92');
select is((select phone_e164 from public.guardian g join public.student_guardian sg on sg.guardian_id = g.id join public.student s on s.id = sg.student_id where s.gr_number = 'GI-3'), '+923217654321',
  'a phone-only row creates a guardian with that phone');
select is((select g.name_en from public.guardian g join public.student_guardian sg on sg.guardian_id = g.id join public.student s on s.id = sg.student_id where s.gr_number = 'GI-3'), 'Asif Ali',
  'with no name in the file the father''s name comes from the student record');
select is((select count(*)::int from public.student_guardian sg join public.student s on s.id = sg.student_id where s.gr_number in ('GI-1', 'GI-2', 'GI-3') and sg.relationship = 'father' and sg.is_primary and sg.receives_billing), 3,
  'each linked father is the primary guardian and receives fee notices');

select is((select message from jsonb_to_recordset(:'r'::jsonb -> 'errors') as e(gr_number text, message text) where gr_number = 'GI-4'), 'The father''s CNIC must have 13 digits.', 'a short CNIC is refused with a clear reason');
select is((select message from jsonb_to_recordset(:'r'::jsonb -> 'errors') as e(gr_number text, message text) where gr_number = 'NOPE-9'), 'No student has this GR number.', 'an unknown GR number is refused');
select is((select count(*)::int from jsonb_to_recordset(:'r'::jsonb -> 'errors') as e(gr_number text, message text) where gr_number = 'GI-1' and message = 'This student already has a father linked.'), 1,
  'a second father for the same student is refused');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.import_guardian_contacts('[{"row": 2, "gr_number": "GI-5", "father_cnic": "35202-5555555-5"}]'::jsonb) ->> 'linked')::int, 0,
  'a principal cannot link a guardian to a student on another campus');

select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok($$ select public.import_guardian_contacts('[]'::jsonb) $$, 'FORBIDDEN', 'a teacher cannot import guardians');

reset role;
select is((select count(distinct family_group_id)::int from public.student where gr_number in ('GI-1', 'GI-2') and family_group_id is not null), 1,
  'siblings whose father has a CNIC land in one family');
select is((select f.father_cnic from public.family_group f join public.student s on s.family_group_id = f.id where s.gr_number = 'GI-2'), '35202-1234567-1',
  'the family is keyed by the father''s CNIC');
select is((select family_group_id from public.student where gr_number = 'GI-3'), null::uuid,
  'a father with only a phone does not form a family');
select is((select count(*)::int from public.guardian where tenant_id = :'tenant_id'), 2, 'only two guardian records were created (one shared by the siblings)');

select * from finish();
rollback;
