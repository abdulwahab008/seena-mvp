-- pgTAP tests for FR-J10: class teacher remarks capture.
begin;
select plan(37);

select public.provision_tenant('test-remark-co', 'Remark Co', 'owner@remark.test');
select id as tenant_id from public.tenant where slug = 'test-remark-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class5 from public.class_level where tenant_id = :'tenant_id' and code = '5' \gset
select public.provision_tenant('test-remark-other', 'Other Remark Co', 'owner@otherremark.test');
select id as other_tenant_id from public.tenant where slug = 'test-remark-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as ct_uid \gset
select gen_random_uuid() as ct2_uid \gset
select gen_random_uuid() as st_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@remark.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@remark.test', 'authenticated', 'authenticated', 'x'),
  (:'ct_uid', 'ct@remark.test', 'authenticated', 'authenticated', 'x'), (:'ct2_uid', 'ct2@remark.test', 'authenticated', 'authenticated', 'x'),
  (:'st_uid', 'st@remark.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'ct_uid', :'tenant_id', 'class_teacher', 'Class Teacher A'), (:'ct2_uid', :'tenant_id', 'class_teacher', 'Class Teacher B'),
  (:'st_uid', :'tenant_id', 'subject_teacher', 'Subject Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class5'::uuid, 'A', 60) as sec_a \gset
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class5'::uuid, 'B', 60) as sec_b \gset
select public.upsert_exam_term(:'campus_id'::uuid, :'session_id'::uuid, 'T1', 'Term 1', 1::smallint, 100.00) as term \gset
reset role;
-- 40 students in section A, 1 in section B.
insert into public.student (tenant_id, campus_id, gr_number, name_en, name_ur, dob, gender)
select :'tenant_id', :'campus_id', 'K-' || lpad(n::text, 4, '0'), 'Remark Kid ' || n, 'طالب علم ' || n, '2015-01-01', 'male' from generate_series(1, 41) n;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_id', :'session_id', s.id, :'class5', case when substr(s.gr_number, 3)::int <= 40 then :'sec_a'::uuid else :'sec_b'::uuid end, substr(s.gr_number, 3)::int
  from public.student s where s.tenant_id = :'tenant_id';
insert into public.section_class_teacher (tenant_id, campus_id, session_id, section_id, staff_id, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec_a', :'ct_uid', current_date - 60),
  (:'tenant_id', :'campus_id', :'session_id', :'sec_b', :'ct2_uid', current_date - 60);
select e.id as e1 from public.enrolment e join public.student s on s.id = e.student_id where s.gr_number = 'K-0001' \gset
select e.id as e2 from public.enrolment e join public.student s on s.id = e.student_id where s.gr_number = 'K-0002' \gset
select e.id as e3 from public.enrolment e join public.student s on s.id = e.student_id where s.gr_number = 'K-0003' \gset
select e.id as e_b from public.enrolment e join public.student s on s.id = e.student_id where s.gr_number = 'K-0041' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ct_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1: all 40 are listed ───────────────────────────────────────────────
select is((select count(*) from public.section_remark_sheet(:'sec_a'::uuid, :'term'::uuid)), 40::bigint, 'AC1: the sheet lists all 40 students of the section');
select is((select count(*) from public.section_remark_sheet(:'sec_a'::uuid, :'term'::uuid) where remark_text is null), 40::bigint, 'none has a remark yet');
select throws_ok(format($$ select * from public.section_remark_sheet(%L, %L) $$, :'sec_b', :'term'), 'FORBIDDEN', 'a class teacher cannot open another section''s sheet');

-- ── library ──────────────────────────────────────────────────────────────
select public.seed_default_remark_library(:'campus_id'::uuid) as seeded \gset
select is(:'seeded'::int, 8, 'a starter library of 8 remarks is available');
select is(public.seed_default_remark_library(:'campus_id'::uuid), 0, 'seeding twice adds nothing');
select public.add_remark_library_entry(:'campus_id'::uuid, 'praise', 'Outstanding effort in all subjects.', 'تمام مضامین میں شاندار محنت۔') as lib1 \gset
select is((select text_ur from public.remark_library where id = :'lib1'::uuid), 'تمام مضامین میں شاندار محنت۔', 'a class teacher can add to the library with an Urdu text');
select throws_ok(format($$ select public.add_remark_library_entry(%L, 'rubbish', 'x') $$, :'campus_id'), '23514', null, 'a library entry has a known category');

-- ── saving remarks, English and Urdu ─────────────────────────────────────
select public.save_term_remark(:'e1'::uuid, :'term'::uuid, 'Outstanding effort in all subjects.', null, :'lib1'::uuid) as r1 \gset
select is((select remark_lang::text from public.term_remark where id = :'r1'::uuid), 'en', 'an English remark is stored as en');
select is((select library_id from public.term_remark where id = :'r1'::uuid), :'lib1'::uuid, 'and remembers the library entry it came from');
select public.save_term_remark(:'e2'::uuid, :'term'::uuid, 'محنتی اور باادب طالب علم۔') as r2 \gset
select is((select remark_lang::text from public.term_remark where id = :'r2'::uuid), 'ur', 'an Urdu remark is detected as ur');
select public.save_term_remark(:'e3'::uuid, :'term'::uuid, 'طالب علم کی کارکردگی 85% بہتر ہے, Grade A') as r3 \gset
select is((select remark_text from public.term_remark where id = :'r3'::uuid), 'طالب علم کی کارکردگی 85% بہتر ہے, Grade A', 'a mixed Urdu/English remark with digits round-trips unchanged');
select is((select remark_lang::text from public.term_remark where id = :'r3'::uuid), 'ur', 'and is classed as Urdu');

-- ── AC2: 250 characters ──────────────────────────────────────────────────
select lives_ok(format($$ select public.save_term_remark(%L, %L, %L) $$, :'e1', :'term', repeat('a', 250)), 'AC2: exactly 250 characters is accepted');
select throws_ok(format($$ select public.save_term_remark(%L, %L, %L) $$, :'e1', :'term', repeat('a', 300)), 'REMARK_TOO_LONG', 'AC2: a 300-character remark is refused');
select throws_ok(format($$ select public.save_term_remark(%L, %L, %L) $$, :'e1', :'term', repeat('ا', 251)), 'REMARK_TOO_LONG', 'and so is 251 Urdu characters');
select is((select char_length(remark_text) from public.term_remark where id = :'r1'::uuid), 250, 'the stored remark stayed at the last accepted version');
select is((select count(*) from public.term_remark where enrolment_id = :'e1'::uuid and exam_term_id = :'term'::uuid), 1::bigint, 'one remark per student per term: saving again replaces');
select throws_ok(format($$ select public.save_term_remark(%L, %L, '   ') $$, :'e1', :'term'), 'REMARK_EMPTY', 'a blank remark is not a remark');

-- ── apply to selected ────────────────────────────────────────────────────
select is(public.apply_term_remark(:'term'::uuid, (select array_agg(enrolment_id) from (select enrolment_id from public.section_remark_sheet(:'sec_a'::uuid, :'term'::uuid) where remark_text is null order by roll_no limit 5) x), 'A satisfactory term. Keep working steadily.', 'en'), 5,
  'AC1: "apply to selected" gives the same remark to 5 students at once');
select throws_ok(format($$ select public.apply_term_remark(%L, array[%L]::uuid[], 'x') $$, :'term', :'e_b'), 'FORBIDDEN', 'but not to a student outside the teacher''s section');

-- ── who may write / read ─────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'st_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_term_remark(%L, %L, 'hello') $$, :'e1', :'term'), 'FORBIDDEN', 'a subject teacher who is not the class teacher cannot write a remark');
select is((select count(*) from public.term_remark), 0::bigint, 'and cannot read the remarks');
select set_config('request.jwt.claims', json_build_object('sub', :'ct2_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.term_remark), 0::bigint, 'another section''s class teacher reads none of these remarks');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.term_remark), 8::bigint, 'the Principal reads every remark of the campus');
select lives_ok(format($$ select public.save_term_remark(%L, %L, 'Principal edit.') $$, :'e_b', :'term'), 'and may write one');

-- ── AC4: remarks_required refuses bulk generation, naming the GR numbers ──
select set_config('request.jwt.claims', json_build_object('sub', :'ct_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_remarks_required(%L, true) $$, :'campus_id'), 'FORBIDDEN', 'a class teacher cannot change the remarks_required setting');
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.report_card_batch), 0::bigint, 'setup: no batch yet');
select lives_ok(format($$ select public.start_report_card_batch(%L, 'section', %L) $$, :'term', :'sec_a'), 'with remarks_required off (the default) a batch starts although 32 remarks are missing');
reset role;
delete from public.report_card_batch where tenant_id = :'tenant_id';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_remarks_required(:'campus_id'::uuid, true);
select public.apply_term_remark(:'term'::uuid, (select array_agg(enrolment_id) from public.section_remark_sheet(:'sec_a'::uuid, :'term'::uuid) where remark_text is null and roll_no <= 37), 'Keep up the good work.') as filled \gset
select is(:'filled'::int, 29, 'setup: 37 of 40 now have a remark (3 do not)');
select throws_ok(format($$ select public.start_report_card_batch(%L, 'section', %L) $$, :'term', :'sec_a'), 'REMARKS_MISSING', 'AC4: with remarks_required on, bulk generation for the section is refused');
select set_config('test.term', :'term', true), set_config('test.sec', :'sec_a', true);
do $$
declare
  v_detail text;
begin
  begin
    perform public.start_report_card_batch(current_setting('test.term')::uuid, 'section', current_setting('test.sec')::uuid);
  exception when others then
    get stacked diagnostics v_detail = pg_exception_detail;
    perform set_config('test.detail', v_detail, true);
  end;
end $$;
select is(current_setting('test.detail'), 'gr_numbers=K-0038,K-0039,K-0040', 'AC4: and lists the 3 GR numbers');
select is((select count(*) from public.report_card_batch), 0::bigint, 'no batch row is left behind');
select public.apply_term_remark(:'term'::uuid, (select array_agg(enrolment_id) from public.section_remark_sheet(:'sec_a'::uuid, :'term'::uuid) where remark_text is null), 'Late remark.');
select lives_ok(format($$ select public.start_report_card_batch(%L, 'section', %L) $$, :'term', :'sec_a'), 'once the 3 are written the batch starts');
select is((select count(*) from public.report_card_batch_item i join public.report_card_batch b on b.id = i.batch_id where b.exam_term_id = :'term'::uuid and i.remark is not null), 40::bigint, 'and every batch item carries the saved remark for the card');

-- ── parents see a remark only once a report card is issued ───────────────
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, phone, phone_confirmed_at, encrypted_password, aud, role) values (:'parent_uid', '923001112222', now(), 'x', 'authenticated', 'authenticated');
insert into public.guardian (tenant_id, name_en, phone_e164, auth_user_id) values (:'tenant_id', 'Remark Parent', '+923001112222', :'parent_uid');
insert into public.student_guardian (tenant_id, student_id, guardian_id, relationship, is_primary, receives_billing)
select :'tenant_id', e.student_id, g.id, 'father', true, true from public.enrolment e, public.guardian g where e.id = :'e1'::uuid and g.auth_user_id = :'parent_uid';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.term_remark), 0::bigint, 'a parent cannot read a remark before the report card is issued');
reset role;
insert into public.report_card (tenant_id, campus_id, exam_term_id, section_id, enrolment_id, revision_no, storage_path, checksum, status, payload_snapshot)
values (:'tenant_id', :'campus_id', :'term', :'sec_a', :'e1', 1, 'x/y.pdf', repeat('a', 64), 'issued', '{}'::jsonb);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*) from public.term_remark), 1::bigint, 'once it is issued the parent reads their own child''s remark (and only that)');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.term_remark) + (select count(*) from public.remark_library), 0::bigint, 'another school sees no remarks or library');

select * from finish();
rollback;
