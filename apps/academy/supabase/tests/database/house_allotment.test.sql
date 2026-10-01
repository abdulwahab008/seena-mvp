-- pgTAP tests for FR-C06: allot house with sibling affinity.
begin;
select plan(26);

select public.provision_tenant('test-house-co', 'House Co', 'owner@house.test');
select id as tenant_id from public.tenant where slug = 'test-house-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-house-other', 'Other House Co', 'owner@otherhouse.test');
select id as other_tenant_id from public.tenant where slug = 'test-house-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as sub_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@house.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@house.test', 'authenticated', 'authenticated', 'x'),
  (:'teach_uid', 't@house.test', 'authenticated', 'authenticated', 'x'), (:'sub_uid', 's@house.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'teach_uid', :'tenant_id', 'class_teacher', 'Class Teacher'), (:'sub_uid', :'tenant_id', 'subject_teacher', 'Subject Teacher');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.create_house(:'campus_id'::uuid, 'Iqbal', '#16a34a', 'Rise') as h_iqbal \gset
select public.create_house(:'campus_id'::uuid, 'Jinnah', '#2563eb') as h_jinnah \gset
select public.create_house(:'campus_id'::uuid, 'Liaquat', '#dc2626') as h_liaquat \gset
select public.create_house(:'campus_id'::uuid, 'Fatima', '#9333ea') as h_fatima \gset
select throws_ok(format($$ select public.create_house(%L, 'Iqbal') $$, :'campus_id'), 'HOUSE_NAME_DUPLICATE', 'house names are unique within a campus');
select throws_ok(format($$ select public.create_house(%L, 'Bad', 'blue') $$, :'campus_id'), '23514', null, 'the colour must be a hex value');

reset role;
-- Two sections of 200, then 400 students; 40 of them are 20 sibling pairs.
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity) values
  (:'tenant_id', :'campus_id', :'session_id', :'class1_id', 'A', 200), (:'tenant_id', :'campus_id', :'session_id', :'class1_id', 'B', 200), (:'tenant_id', :'campus_id', :'session_id', :'class1_id', 'C', 50);
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_id', 'H-' || lpad(n::text, 4, '0'), 'House Kid ' || n, '2015-01-01', 'male' from generate_series(1, 400) n;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select :'tenant_id', :'campus_id', :'session_id', s.id, :'class1_id',
       (select id from public.class_section where campus_id = :'campus_id' and name = case when substr(s.gr_number, 3)::int <= 200 then 'A' else 'B' end)
  from public.student s where s.tenant_id = :'tenant_id';
-- Pairs (1,2), (3,4) ... (39,40) are siblings.
insert into public.family_group (tenant_id) select :'tenant_id' from generate_series(1, 20);
with fg as (select id, row_number() over (order by id) rn from public.family_group where tenant_id = :'tenant_id'),
     st as (select id, substr(gr_number, 3)::int n from public.student where tenant_id = :'tenant_id' and substr(gr_number, 3)::int <= 40)
update public.student s set family_group_id = fg.id from st join fg on fg.rn = (st.n + 1) / 2 where s.id = st.id;

-- Student 1 is already in Iqbal House (placed by an earlier run).
select id as stu1 from public.student where tenant_id = :'tenant_id' and gr_number = 'H-0001' \gset
select id as stu2 from public.student where tenant_id = :'tenant_id' and gr_number = 'H-0002' \gset
select id as stu41 from public.student where tenant_id = :'tenant_id' and gr_number = 'H-0041' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_student_house(:'stu1'::uuid, :'h_iqbal'::uuid, '2026-04-01'::date);

-- ── AC1: sibling joins Iqbal House with reason sibling_match ─────────────
select public.auto_assign_houses(:'campus_id'::uuid, :'session_id'::uuid) as run1 \gset
select is((select house_id from public.student where id = :'stu2'::uuid), :'h_iqbal'::uuid, 'AC1: the sibling of a student in Iqbal House is placed in Iqbal House');
select is((select reason from public.student_house_history where student_id = :'stu2'::uuid and to_date is null), 'sibling_match', 'AC1: and the reason sibling_match is stored');
select is((:'run1'::jsonb ->> 'assigned')::int, 399, 'every un-housed student was placed');
select is((select count(*) from public.student s join public.student_house_history h on h.student_id = s.id and h.to_date is null
            where s.tenant_id = :'tenant_id' and h.reason = 'sibling_match'), 20::bigint, 'all 20 sibling pairs are kept together (20 followers)');
select is((select count(*) from (select family_group_id from public.student where tenant_id = :'tenant_id' and family_group_id is not null group by family_group_id having count(distinct house_id) > 1) x), 0::bigint, 'no family is split across houses');

-- ── AC2: capacity balancing across 400 students and 4 houses ─────────────
select ok((select max(c) <= min(c) * 1.10 from (select count(*) c from public.student where tenant_id = :'tenant_id' group by house_id) x), 'AC2: no house holds more than 10% more students than the smallest');
select is((select count(*) from public.student where tenant_id = :'tenant_id' and house_id is null), 0::bigint, 'everyone has a house');
select is(((public.auto_assign_houses(:'campus_id'::uuid, :'session_id'::uuid)) ->> 'assigned')::int, 0, 'running again assigns nobody (idempotent)');

-- ── AC3: a house with students cannot be deleted ─────────────────────────
reset role;
select throws_ok(format($$ delete from public.house where id = %L $$, :'h_jinnah'), '23503', null, 'AC3: deleting a house referenced by ~100 students is blocked by ON DELETE RESTRICT');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.delete_house(%L) $$, :'h_jinnah'), 'HOUSE_IN_USE', 'delete_house reports HOUSE_IN_USE');
select public.create_house(:'campus_id'::uuid, 'Spare') as h_spare \gset
select lives_ok(format($$ select public.delete_house(%L) $$, :'h_spare'), 'an unused house can be deleted');

-- ── AC4: a mid-year move does not rewrite last term's points ─────────────
select public.award_house_points(:'stu41'::uuid, 10, '2026-11-10'::date, 'sports', 'Relay race') as pt1 \gset
select house_id as old_house from public.student where id = :'stu41'::uuid \gset
select id as new_house from public.house where campus_id = :'campus_id' and id <> :'old_house'::uuid limit 1 \gset
select public.set_student_house(:'stu41'::uuid, :'new_house'::uuid, '2027-02-01'::date);
select is((select house_id from public.student where id = :'stu41'::uuid), :'new_house'::uuid, 'the student is now in the new house');
select is(public.house_on_date(:'stu41'::uuid, '2026-11-10'::date), :'old_house'::uuid, 'AC4: history says November belonged to the previous house');
select is(public.house_on_date(:'stu41'::uuid, '2027-01-31'::date), :'old_house'::uuid, 'the previous house holds through 31 January');
select is(public.house_on_date(:'stu41'::uuid, '2027-02-01'::date), :'new_house'::uuid, 'and the new house from 1 February');
select is((select points from public.house_standings(:'campus_id'::uuid, '2026-11-01', '2026-11-30') where house_id = :'old_house'::uuid), 10::bigint, 'AC4: November''s points remain with the previous house');
select is((select points from public.house_standings(:'campus_id'::uuid, '2026-11-01', '2026-11-30') where house_id = :'new_house'::uuid), 0::bigint, 'and none moved to the new house');
select throws_ok(format($$ select public.set_student_house(%L, %L, '2027-01-01') $$, :'stu41', :'old_house'), 'EFFECTIVE_DATE_BEFORE_CURRENT_HOUSE', 'a move cannot be dated before the current house began');

-- ── balancing off: non-siblings are spread by hash, siblings still follow ─
select public.set_house_capacity_balancing(:'campus_id'::uuid, false);
reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender, family_group_id)
select :'tenant_id', :'campus_id', 'H-9' || lpad(n::text, 3, '0'), 'Late Kid ' || n, '2015-01-01', 'female', case when n <= 2 then (select family_group_id from public.student where id = :'stu1'::uuid) end from generate_series(1, 6) n;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select :'tenant_id', :'campus_id', :'session_id', s.id, :'class1_id', (select id from public.class_section where campus_id = :'campus_id' and name = 'C')
  from public.student s where s.tenant_id = :'tenant_id' and s.gr_number like 'H-9%';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.auto_assign_houses(:'campus_id'::uuid, :'session_id'::uuid) as run2 \gset
select is((:'run2'::jsonb ->> 'spread')::int, 4, 'with balancing off, non-siblings use the spread rule');
select is((:'run2'::jsonb ->> 'sibling_match')::int, 2, 'and siblings still follow the family');

-- ── permissions and isolation ────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'sub_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.set_student_house(%L, %L) $$, :'stu1', :'h_jinnah'), 'FORBIDDEN', 'a subject teacher cannot move students between houses');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'class_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.create_house(%L, 'Rogue') $$, :'campus_id'), 'FORBIDDEN', 'a class teacher cannot create houses (principal only)');
select lives_ok(format($$ select public.set_student_house(%L, %L, '2027-03-01') $$, :'stu1', :'h_jinnah'), 'but a class teacher can move a student');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.house) + (select count(*) from public.student_house_history) + (select count(*) from public.house_point), 0::bigint, 'another school sees no houses, history or points');

select * from finish();
rollback;
