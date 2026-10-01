-- pgTAP tests for FR-S10: year-on-year comparison report.
begin;
select plan(33);

select public.provision_tenant('test-yoy-co', 'YoY Co', 'owner@yoy.test');
select id as tenant_id from public.tenant where slug = 'test-yoy-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-yoy-other', 'Other YoY Co', 'owner@otheryoy.test');
select id as other_tenant_id from public.tenant where slug = 'test-yoy-other' \gset
select id as session_default from public.academic_session where tenant_id = :'tenant_id' \gset
-- the default session would overlap the fixtures
delete from public.academic_session where id = :'session_default';

-- A is the Punjab-board campus (April-March); B is Cambridge (August-July); D opened in September 2025.
insert into public.campus (tenant_id, code, name, created_at) values (:'tenant_id', 'YB', 'Cambridge Campus', '2025-01-01') returning id as campus_b \gset
insert into public.campus (tenant_id, code, name, created_at) values (:'tenant_id', 'YD', 'New Campus', '2025-09-15') returning id as campus_d \gset
update public.campus set created_at = '2025-01-01' where id = :'campus_a';

insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status) values
  (:'tenant_id', null, '2025-26', '2025-04-01', '2026-03-31', false, 'closed') returning id as s1 \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status) values
  (:'tenant_id', null, '2026-27', '2026-04-01', '2027-03-31', false, 'closed') returning id as s2 \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status) values
  (:'tenant_id', :'campus_b', 'Cambridge 2025-26', '2025-08-01', '2026-07-31', false, 'closed') returning id as c1 \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status) values
  (:'tenant_id', :'campus_b', 'Cambridge 2026-27', '2026-08-01', '2027-07-31', false, 'closed') returning id as c2 \gset

-- Campus A: one aggregate row on the 15th of every month. Session 1 collects 100,000 paisa x month index;
-- session 2 collects 120,000 x index, except index 2 where it collects 345,678 against 333,333.
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, marked_sections, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select :'tenant_id', :'campus_a', (date '2025-04-15' + (i - 1) * interval '1 month')::date, 523, 500, 1, case when i = 2 then 333333 else 100000 * i end, 1000000, 200000, 200000 from generate_series(1, 12) i;
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, marked_sections, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select :'tenant_id', :'campus_a', (date '2026-04-15' + (i - 1) * interval '1 month')::date, 550, 520, 1, case when i = 2 then 345678 else 120000 * i end, 1000000, 100000, 100000 from generate_series(1, 12) i;
-- Campus B (Cambridge): data from August 2025 on, in its own session calendar
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, marked_sections, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select :'tenant_id', :'campus_b', (date '2025-08-15' + (i - 1) * interval '1 month')::date, 200, 190, 1, 50000 * i, 400000, 0, 0 from generate_series(1, 12) i;
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, marked_sections, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select :'tenant_id', :'campus_b', (date '2026-08-15' + (i - 1) * interval '1 month')::date, 220, 210, 1, 60000 * i, 400000, 0, 0 from generate_series(1, 12) i;
-- Campus D opened mid-September 2025: rows from October 2025 only (session 1), the whole of session 2
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, marked_sections, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select :'tenant_id', :'campus_d', (date '2025-10-15' + (i - 1) * interval '1 month')::date, 80, 70, 1, 10000 * i, 100000, 0, 0 from generate_series(1, 6) i;
insert into public.agg_campus_day (tenant_id, campus_id, day, enrolled_count, present_count, marked_sections, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select :'tenant_id', :'campus_d', (date '2026-04-15' + (i - 1) * interval '1 month')::date, 90, 80, 1, case when i <= 6 then 12000 * i else 12000 * (i - 6) end, 100000, 0, 0 from generate_series(1, 12) i;

select has_view('public', 'v_session_month_index', 'v_session_month_index exists');
select has_function('public', 'fn_yoy_series', array['uuid', 'uuid[]', 'text', 'uuid[]'], 'fn_yoy_series(tenant, campuses, metric, sessions) exists');
select is((select count(*)::int from public.v_session_month_index where session_id = :'s1'), 12, 'a 12-month session has indices 1..12');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b', :'campus_d'))::text, true);

-- ── AC1: index 1 is the session's first month, whatever the calendar says ──
select is((select period_label from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', array[:'s1']::uuid[]) where month_index = 1), 'Apr 2025', 'AC1: Punjab session index 1 is April 2025');
select is((select period_label from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', array[:'s2']::uuid[]) where month_index = 1), 'Apr 2026', 'AC1: and the next session''s index 1 is April 2026');
select is((select value from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', array[:'s1']::uuid[]) where month_index = 1), 100000::numeric, 'index 1 carries April''s collections');
select is((select period_label from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_b']::uuid[], 'fees_collected', array[:'c1']::uuid[]) where month_index = 1), 'Aug 2025', 'AC1: a Cambridge campus''s index 1 is August 2025');
select is((select value from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_b']::uuid[], 'fees_collected', array[:'c1']::uuid[]) where month_index = 1), 50000::numeric, 'and carries August''s collections, not April''s');
select is((select count(*)::int from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a', :'campus_b']::uuid[], 'fees_collected', array[:'s1', :'c1']::uuid[])), 24, 'mixed calendars in one call: each session keeps its own 12 indices');
select is((select value from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a', :'campus_b']::uuid[], 'fees_collected', array[:'c1']::uuid[]) where month_index = 1), 50000::numeric, 'a campus-scoped session ignores the other campuses even if they are selected');

-- ── AC4: absolute and percentage change to one decimal ────────────────────
select is((select abs_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 3), 60000::numeric, 'AC4: absolute change is shown (360,000 vs 300,000 paisa)');
select is((select pct_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 3), 20.0::numeric, 'AC4: and the percentage change');
select is((select pct_change::text from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 2), '3.7', 'AC4: 345,678 vs 333,333 is +3.7%, one decimal place');
select is((select abs_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 2), 12345::numeric, 'AC4: absolute change alongside it');
select is((select pct_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'enrolment', :'s2'::uuid, :'s1'::uuid) where month_index = 1), 5.2::numeric, 'enrolment 550 vs 523 is +5.2%');
select is((select abs_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'enrolment', :'s2'::uuid, :'s1'::uuid) where month_index = 1), 27::numeric, 'and +27 students');
select is((select pct_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'outstanding', :'s2'::uuid, :'s1'::uuid) where month_index = 1), -50.0::numeric, 'a fall is reported as a negative change');

-- ── AC2: a campus without early data -> "no data", excluded from the change ──
select is((select status from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 1), 'no_data', 'AC2: April 2025 for a campus that opened in September is "no data"');
select is((select pct_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 1), null::numeric, 'AC2: with no percentage at all (not -100%)');
select is((select prior_value from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 1), null::numeric, 'AC2: and the missing side is null, not zero');
select is((select count(*)::int from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where status = 'no_data'), 6, 'AC2: the six months before it had data (April-September 2025) are all no_data');
select is((select months_excluded || '/' || months_compared from public.fn_yoy_overall(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid)), '6/6', 'AC2: the overall figure compares only the 6 months both sessions have');
select is((select current_value from public.fn_yoy_overall(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid)), (12000 * 1 + 12000 * 2 + 12000 * 3 + 12000 * 4 + 12000 * 5 + 12000 * 6)::numeric, 'AC2: summed over those 6 months only, not the whole session');
select is((select pct_change from public.fn_yoy_overall(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid)), 20.0::numeric, 'AC2: like-for-like growth is +20.0%, not distorted by the missing months');
reset role;
-- a zero baseline is the normal case for a new campus and must not divide
update public.agg_campus_day set collected_paisa = 0 where campus_id = :'campus_d' and day = '2025-10-15';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a', :'campus_b', :'campus_d'))::text, true);
select is((select status || '/' || coalesce(pct_change::text, 'null') from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 7), 'no_baseline/null', 'a zero prior value reports "no baseline" instead of dividing by zero');
select is((select abs_change from public.fn_yoy_compare(:'tenant_id'::uuid, array[:'campus_d']::uuid[], 'fees_collected', :'s2'::uuid, :'s1'::uuid) where month_index = 7), 12000::numeric, 'the absolute change is still shown');
select throws_ok(format($$ select * from public.fn_yoy_series(%L, array[%L]::uuid[], 'no_such_metric', array[%L]::uuid[]) $$, :'tenant_id', :'campus_a', :'s1'), 'METRIC_NOT_COMPARABLE', 'an unknown metric is refused');
reset role;

-- ── AC3: classes align on stable codes, not display names ─────────────────
insert into public.stream (tenant_id, code, name_en, board, applies_from_ordinal) values (:'tenant_id', 'SCI', 'Science', 'FBISE', 9) returning id as stream_id \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values
  (:'tenant_id', :'campus_a', :'s1', :'class9', '9 Science', 40, :'stream_id') returning id as sec1 \gset
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity, stream_id) values
  (:'tenant_id', :'campus_a', :'s2', :'class9', '9 Pre-Medical', 40, :'stream_id') returning id as sec2 \gset
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'YO' || g, 'Yoy Kid ' || g, '2011-01-01', 'male' from generate_series(1, 6) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select tenant_id, campus_id, :'s1', id, :'class9', :'sec1' from public.student where tenant_id = :'tenant_id' and gr_number in ('YO1', 'YO2', 'YO3', 'YO4');
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id)
select tenant_id, campus_id, :'s2', id, :'class9', :'sec2' from public.student where tenant_id = :'tenant_id' and gr_number in ('YO1', 'YO2', 'YO3', 'YO5', 'YO6');
update public.stream set name_en = 'Pre-Medical' where id = :'stream_id';

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(distinct (class_code, group_code))::int from public.fn_yoy_class_enrolment(:'tenant_id'::uuid, array[:'campus_a']::uuid[], array[:'s1', :'s2']::uuid[])), 1, 'AC3: "9 Science" and "9 Pre-Medical" are the same cohort: one (class, group) row');
select is((select group_code from public.fn_yoy_class_enrolment(:'tenant_id'::uuid, array[:'campus_a']::uuid[], array[:'s1']::uuid[])), 'SCI', 'AC3: aligned on the stable group code');
select is((select string_agg(enrolled::text, '/' order by session_id = :'s2') from public.fn_yoy_class_enrolment(:'tenant_id'::uuid, array[:'campus_a']::uuid[], array[:'s1', :'s2']::uuid[])), '4/5', 'AC3: 4 students in session 1, 5 in session 2');
select is((select section_names from public.fn_yoy_class_enrolment(:'tenant_id'::uuid, array[:'campus_a']::uuid[], array[:'s2']::uuid[])), array['9 Pre-Medical'], 'the session''s own section names are still reported alongside');

-- ── isolation ─────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text, true);
select is((select count(*)::int from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a']::uuid[], 'fees_collected', array[:'s1']::uuid[])), 0, 'another school gets nothing back, even naming this school''s ids');
select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'))::text, true);
select is((select value from public.fn_yoy_series(:'tenant_id'::uuid, array[:'campus_a', :'campus_b']::uuid[], 'fees_collected', array[:'s1']::uuid[]) where month_index = 5), 50000::numeric, 'a principal limited to campus B sees only campus B''s figures when A is requested too (index 5 = August: B''s first month)');
reset role;

select * from finish();
rollback;
