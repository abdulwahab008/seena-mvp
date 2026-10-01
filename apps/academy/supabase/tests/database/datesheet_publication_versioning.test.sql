-- pgTAP tests for FR-I04: datesheet publication and versioning.
--
--   AC1  Publishing a draft of 8 slots creates version 1, copies the slots into an
--        immutable snapshot, and makes the source read-only.
--   AC2  A paper moved by one day and republished is version 2; version 1 stays
--        retrievable; the parent view is flagged "revised" with the changed row.
--   AC3  A datesheet still in draft is not listed to a parent.
--   AC4  (PDF with English + Urdu names and the embedded font is rendered by the
--        app; covered by lib/datesheet/html.test.ts.)
begin;
select plan(44);

select public.provision_tenant('test-dsversion-co', 'Datesheet Version Co', 'owner@dsversion.test');
select id as tenant_id from public.tenant where slug = 'test-dsversion-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select public.provision_tenant('test-dsversion-other', 'Other Datesheet Version Co', 'owner@otherdsversion.test');
select id as other_tenant_id from public.tenant where slug = 'test-dsversion-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as stranger_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@dsversion.test', 'authenticated', 'authenticated', 'x'), (:'ec_uid', 'e@dsversion.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@dsversion.test', 'authenticated', 'authenticated', 'x'), (:'parent_uid', 'p@dsversion.test', 'authenticated', 'authenticated', 'x'),
  (:'stranger_uid', 's@dsversion.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Exam Controller'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_subject('S' || g, 'Subject ' || g, 'مضمون ' || g) from generate_series(1, 8) g;
select public.upsert_class_subject(:'campus_id', :'session_id', :'class9', s.id, 4::smallint) from public.subject s where s.tenant_id = :'tenant_id' and s.code like 'S%';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class9'::uuid, 'A', 45) as sec9 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'T1', 'First Term', 1::smallint, 100.00) as term1 \gset
select public.upsert_exam_term(:'campus_id', :'session_id', 'W1', 'Weekly Test', 2::smallint, 0.00, false) as term2 \gset
select public.activate_exam_terms(:'session_id'::uuid, :'campus_id'::uuid) as _a \gset
select public.upsert_exam_subject(:'term1', cs.id, '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb)
  from public.class_subject cs where cs.tenant_id = :'tenant_id';
select public.create_student(:'campus_id'::uuid, 'Version Kid', '2011-01-01'::date, 'male') as st1 \gset
select public.enrol_student(:'sec9'::uuid, :'st1'::uuid) as enr1 \gset
select public.fn_find_or_create_guardian(p_name_en => 'Version Father', p_phone_e164 => '+923007770001') as g1 \gset
select public.link_guardian(:'st1'::uuid, :'g1'::uuid, 'father'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'parent_uid' where id = :'g1';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_datesheet(:'campus_id'::uuid, :'term1'::uuid, 'First Term datesheet') as ds \gset
select public.create_datesheet(:'campus_id'::uuid, :'term2'::uuid, 'Weekly datesheet') as ds_empty \gset
-- Eight papers, one per day from 8 Sept (every pupil sits all eight, so they cannot overlap).
select public.save_datesheet_slot(:'ds'::uuid, x.id, (date '2026-09-07' + x.n)::date, '09:00'::time, '11:00'::time)
  from (select es.id, (row_number() over (order by es.id))::int as n from public.exam_subject es where es.tenant_id = :'tenant_id') x;
select is((select count(*) from public.datesheet_slot where datesheet_id = :'ds'::uuid), 8::bigint, 'the draft holds 8 slots');

-- ── AC3: a draft is not listed to a parent ────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((public.fn_portal_datesheet(:'enr1'::uuid) ->> 'has_datesheet')::boolean, false, 'AC3: a parent sees no datesheet while it is a draft');
select is((select count(*) from public.datesheet_version) + (select count(*) from public.datesheet_slot_snapshot) + (select count(*) from public.datesheet_slot) + (select count(*) from public.datesheet), 0::bigint, 'AC3: and reads no draft row either');

-- ── AC1: publish ──────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.publish_datesheet(%L) $$, :'ds'), 'FORBIDDEN', 'a teacher cannot publish');
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.publish_datesheet(%L) $$, :'ds_empty'), 'DATESHEET_EMPTY', 'a datesheet with no papers cannot be published');
select is(public.publish_datesheet(:'ds'::uuid, 'First issue'), 1, 'AC1: publishing creates version 1');
select is((select count(*) from public.datesheet_slot_snapshot s join public.datesheet_version v on v.id = s.version_id where v.datesheet_id = :'ds'::uuid and v.version_no = 1), 8::bigint, 'AC1: all 8 slots are copied into the snapshot');
select is((select status from public.datesheet where id = :'ds'::uuid), 'published', 'AC1: the source datesheet is now published');
select throws_ok(format($$ select public.save_datesheet_slot(%L, %L, '2026-10-01', '09:00', '11:00') $$, :'ds', (select exam_subject_id from public.datesheet_slot where datesheet_id = :'ds'::uuid limit 1)), 'DATESHEET_READONLY', 'AC1: and read-only for slot edits');
select throws_ok(format($$ select public.delete_datesheet_slot(%L) $$, (select id from public.datesheet_slot where datesheet_id = :'ds'::uuid limit 1)), 'DATESHEET_READONLY', 'AC1: or removal');
select throws_ok(format($$ select public.publish_datesheet(%L) $$, :'ds'), 'DATESHEET_NOT_DRAFT', 'a published datesheet cannot be published again');
select is((select count(*) from public.datesheet_slot_snapshot where datesheet_id = :'ds'::uuid and change_kind = 'new'), 8::bigint, 'every row of the first version is new');

reset role;
select throws_ok(format($$ update public.datesheet_slot set hall_id = null where datesheet_id = %L $$, :'ds'), 'DATESHEET_READONLY', 'AC1: the working slots are read-only even to a raw statement');
select throws_ok(format($$ update public.datesheet_slot_snapshot set start_at = start_at + interval '1 day' where datesheet_id = %L $$, :'ds'), '42501', null, 'AC1: the snapshot is immutable (update)');
select throws_ok(format($$ delete from public.datesheet_slot_snapshot where datesheet_id = %L $$, :'ds'), '42501', null, 'AC1: and cannot be deleted');
select throws_ok(format($$ update public.datesheet_version set version_no = 9 where datesheet_id = %L $$, :'ds'), '42501', null, 'a version row cannot be renumbered');
select throws_ok(format($$ delete from public.datesheet_version where datesheet_id = %L $$, :'ds'), '42501', null, 'or deleted');
select throws_ok(format($$ truncate public.datesheet_slot_snapshot $$), null, null, 'or truncated');

-- ── the parent now sees version 1 ─────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((public.fn_portal_datesheet(:'enr1'::uuid) ->> 'version_no')::int, 1, 'the parent sees version 1');
select is((public.fn_portal_datesheet(:'enr1'::uuid) ->> 'revised')::boolean, false, 'with no revised banner');
select is(jsonb_array_length(public.fn_portal_datesheet(:'enr1'::uuid) -> 'rows'), 8, 'and all 8 papers');
select is((select count(*) from public.datesheet_slot_snapshot), 8::bigint, 'the parent can read the class snapshot under the policy');
select is((select count(*) from public.datesheet_slot), 0::bigint, 'but never the working slots');
select set_config('request.jwt.claims', json_build_object('sub', :'stranger_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select throws_ok(format($$ select public.fn_portal_datesheet(%L) $$, :'enr1'), 'FORBIDDEN', 'a guardian of another child is refused');
select is((select count(*) from public.datesheet_slot_snapshot) + (select count(*) from public.datesheet_version), 0::bigint, 'and reads no snapshot');

-- ── AC2: a paper moves by a day, republished as version 2 ─────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.reopen_datesheet(:'ds'::uuid);
select is((select status from public.datesheet where id = :'ds'::uuid), 'draft', 'reopening makes the datesheet editable again');
select throws_ok(format($$ select public.reopen_datesheet(%L) $$, :'ds'), 'DATESHEET_NOT_PUBLISHED', 'only a published datesheet can be reopened');
select exam_subject_id as moved_es, start_at as moved_from from public.datesheet_slot where datesheet_id = :'ds'::uuid order by start_at desc limit 1 \gset
select public.save_datesheet_slot(:'ds'::uuid, :'moved_es'::uuid, ((:'moved_from'::timestamptz at time zone 'Asia/Karachi')::date + 1), '09:00'::time, '11:00'::time);
select is(public.publish_datesheet(:'ds'::uuid, 'Rain delay: last paper moved a day'), 2, 'AC2: republishing creates version 2');
select is((select count(*) from public.datesheet_slot_snapshot s join public.datesheet_version v on v.id = s.version_id where v.datesheet_id = :'ds'::uuid and v.version_no = 1), 8::bigint, 'AC2: version 1 is still there, all 8 rows');
select is((select status from public.datesheet_version where datesheet_id = :'ds'::uuid and version_no = 1), 'superseded', 'AC2: marked superseded');
select is((select status from public.datesheet_version where datesheet_id = :'ds'::uuid and version_no = 2), 'published', 'AC2: and version 2 is the published one');
select is((select count(*) from public.datesheet_slot_snapshot s join public.datesheet_version v on v.id = s.version_id where v.datesheet_id = :'ds'::uuid and v.version_no = 2 and s.change_kind = 'moved'), 1::bigint, 'AC2: exactly one row of version 2 is flagged moved');
select is((select count(*) from public.datesheet_slot_snapshot s join public.datesheet_version v on v.id = s.version_id where v.datesheet_id = :'ds'::uuid and v.version_no = 2 and s.change_kind = 'unchanged'), 7::bigint, 'AC2: and the other 7 unchanged');
select is((select s.previous_start_at from public.datesheet_slot_snapshot s join public.datesheet_version v on v.id = s.version_id where v.datesheet_id = :'ds'::uuid and v.version_no = 2 and s.change_kind = 'moved'), :'moved_from'::timestamptz, 'AC2: the moved row remembers when it used to be');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb)::text, true);
select is((public.fn_portal_datesheet(:'enr1'::uuid) ->> 'revised')::boolean, true, 'AC2: the parent view carries the revised banner');
select is((select count(*) from jsonb_array_elements(public.fn_portal_datesheet(:'enr1'::uuid) -> 'rows') r where (r ->> 'changed')::boolean), 1::bigint, 'AC2: with the one changed row highlighted');
select is((public.fn_portal_datesheet(:'enr1'::uuid, null, 1) ->> 'is_latest')::boolean, false, 'AC2: version 1 is still retrievable and marked as not the latest');
select is(jsonb_array_length(public.fn_portal_datesheet(:'enr1'::uuid) -> 'versions'), 2, 'AC2: both versions are listed');

-- ── a clash stored by other means blocks publication ──────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.reopen_datesheet(:'ds'::uuid);
reset role;
update public.datesheet_slot set start_at = (select start_at from public.datesheet_slot where datesheet_id = :'ds'::uuid order by start_at limit 1),
  end_at = (select end_at from public.datesheet_slot where datesheet_id = :'ds'::uuid order by start_at limit 1)
 where id = (select id from public.datesheet_slot where datesheet_id = :'ds'::uuid order by start_at desc limit 1);
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.publish_datesheet(%L) $$, :'ds'), 'DATESHEET_HAS_CLASHES', 'a datesheet with a pupil in two overlapping papers cannot be published');

-- ── PDF bookkeeping and the bucket ────────────────────────────────────────
select id as v1_id from public.datesheet_version where datesheet_id = :'ds'::uuid and version_no = 1 \gset
select public.record_datesheet_pdf(:'v1_id'::uuid, :'tenant_id' || '/' || :'ds' || '/v1.pdf');
select is((select pdf_path from public.datesheet_version where id = :'v1_id'::uuid), :'tenant_id' || '/' || :'ds' || '/v1.pdf', 'the rendered PDF path is recorded against the version');
select throws_ok(format($$ select public.record_datesheet_pdf(%L, 'elsewhere/v1.pdf') $$, :'v1_id'), 'PATH_INVALID', 'a path outside the datesheet''s own folder is refused');
reset role;
select is((select public from storage.buckets where id = 'datesheets'), false, 'the datesheets bucket is private');
select is((select count(*) from pg_policies where schemaname = 'storage' and tablename = 'objects' and qual like '%datesheets%'), 0::bigint, 'with no read policy: access is by signed URL only');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.datesheet_version) + (select count(*) from public.datesheet_slot_snapshot), 0::bigint, 'another school sees no version or snapshot');

select * from finish();
rollback;
