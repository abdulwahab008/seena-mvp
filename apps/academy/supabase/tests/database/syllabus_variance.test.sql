-- pgTAP tests for FR-H12: syllabus progress variance against plan.
begin;
select plan(24);

select public.provision_tenant('test-var-co', 'Variance Co', 'owner@var.test');
select id as tenant_id from public.tenant where slug = 'test-var-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
select public.provision_tenant('test-var-other', 'Other Variance Co', 'owner@othervar.test');
select id as other_tenant_id from public.tenant where slug = 'test-var-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as teach_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@var.test', 'authenticated', 'authenticated', 'x'), (:'prin_uid', 'p@var.test', 'authenticated', 'authenticated', 'x'), (:'teach_uid', 't@var.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'), (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher');
insert into public.subject (tenant_id, code, name_en, name_ur) values
  (:'tenant_id', 'PHY', 'Physics', 'طبیعیات'), (:'tenant_id', 'MTH', 'Maths', 'ریاضی'), (:'tenant_id', 'CHM', 'Chemistry', 'کیمیا');
select id as phy from public.subject where tenant_id = :'tenant_id' and code = 'PHY' \gset
select id as mth from public.subject where tenant_id = :'tenant_id' and code = 'MTH' \gset
select id as chm from public.subject where tenant_id = :'tenant_id' and code = 'CHM' \gset
select date_trunc('month', app.fn_karachi_today())::date as this_month \gset

-- ── AC1 / AC2: the classification rule ───────────────────────────────────
select is((select classification from public.classify_syllabus_variance(60, 43)), 'behind', 'AC1: expected 60 and actual 43 is behind');
select is((select variance_pct from public.classify_syllabus_variance(60, 43)), -17.00::numeric, 'AC1: with variance -17.00');
select is((select classification from public.classify_syllabus_variance(60, 57)), 'on_track', 'AC2: expected 60 and actual 57 is on track');
select is((select classification from public.classify_syllabus_variance(60, 55)), 'on_track', 'a shortfall of exactly 5 points is still on track');
select is((select classification from public.classify_syllabus_variance(null, 0)), 'no_plan', 'AC3: no expected value is no_plan, not behind');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 30) as sec \gset
-- Physics: unit A (30 periods) was due last month, unit B (30 periods) next month.
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'phy'::uuid, 'FBISE'::public.board,
  jsonb_build_array(jsonb_build_object('title', 'Due', 'planned_periods', 30, 'target_month', to_char(:'this_month'::date - interval '1 month', 'YYYY-MM-01')),
                    jsonb_build_object('title', 'Future', 'planned_periods', 30, 'target_month', to_char(:'this_month'::date + interval '1 month', 'YYYY-MM-01'))));
-- Maths: no target months at all.
select public.save_syllabus(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, :'mth'::uuid, 'FBISE'::public.board, '[{"title":"Algebra","planned_periods":10}]'::jsonb);
reset role;
insert into public.section_subject_teacher (tenant_id, campus_id, session_id, section_id, subject_id, staff_id, effective_from) values
  (:'tenant_id', :'campus_id', :'session_id', :'sec', :'phy', :'teach_uid', current_date - 60);

select set_config('request.jwt.claims', '', true);
select public.refresh_syllabus_variance() as n0 \gset
select is((select expected_pct from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'phy'), 50.00::numeric, 'AC5: the unit due next month contributes 0 to expected (30 of 60 periods = 50%)');
select is((select classification || ':' || variance_pct::text from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'phy'), 'behind:-50.00', 'with nothing completed the pair is behind by 50.00');
select is((select expected_pct from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'mth'), null, 'AC3: a subject with no target months has expected NULL');
select is((select classification from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'mth'), 'no_plan', 'AC3: and is reported as no_plan');

-- Completing the due unit closes the gap; completing the future one is "ahead", still on track.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select id as u_due from public.syllabus_unit where tenant_id = :'tenant_id' and title = 'Due' \gset
select public.set_syllabus_coverage(:'sec'::uuid, :'phy'::uuid, :'u_due'::uuid, 'completed', null, app.fn_karachi_today());
reset role;
select set_config('request.jwt.claims', '', true);
select public.refresh_syllabus_variance();
select is((select actual_pct from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'phy'), 50.00::numeric, 'actual is the weighted completed share (30 of 60)');
select is((select classification from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'phy'), 'on_track', 'and the pair is back on track');
select is((select actual_pct from app.mv_syllabus_variance where section_id = :'sec' and subject_id = :'phy'),
          (select coverage_pct from (select app.fn_coverage_pct(:'sec'::uuid, :'phy'::uuid) as coverage_pct) x), 'the matview agrees with coverage_pct()');
select ok(exists (select 1 from pg_indexes where schemaname = 'app' and indexname = 'uq_mv_variance_pair' and indexdef ilike '%unique%'), 'a unique index makes CONCURRENTLY refresh possible');
select ok(exists (select 1 from pg_indexes where schemaname = 'app' and indexname = 'idx_mv_variance' and indexdef ilike '%campus_id, classification, variance_pct%'), 'idx_mv_variance covers (campus_id, classification, variance_pct)');
select ok(to_regclass('cron.job') is null
          or (xpath('/row/c/text()', query_to_xml('select count(*) as c from cron.job where jobname = ''syllabus_variance_refresh'' and schedule = ''0 0 * * *''', false, true, '')))[1]::text = '1',
          'the 05:00 PKT (00:00 UTC) refresh is scheduled where pg_cron exists');

-- ── AC4: 42 sections x 8 subjects = 336 pairs read in under 2 seconds ────
insert into public.subject (tenant_id, code, name_en, name_ur) select :'tenant_id', 'S' || n, 'Subject ' || n, 'مضمون ' || n from generate_series(1, 8) n;
insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
select :'tenant_id', :'campus_id', :'session_id', :'class1_id', 'P' || lpad(n::text, 2, '0'), 30 from generate_series(1, 41) n;
insert into public.syllabus_unit (tenant_id, campus_id, session_id, class_level_id, subject_id, board, sequence, title, planned_periods, target_month)
select :'tenant_id', :'campus_id', :'session_id', :'class1_id', s.id, 'FBISE', u, 'Unit ' || u, 8, :'this_month'::date - make_interval(months => u)
  from public.subject s cross join generate_series(1, 3) u where s.tenant_id = :'tenant_id' and s.code like 'S%';
select set_config('request.jwt.claims', '', true);
select public.refresh_syllabus_variance() as n_all \gset
select is((select count(*) from app.mv_syllabus_variance where tenant_id = :'tenant_id' and subject_id in (select id from public.subject where tenant_id = :'tenant_id' and code like 'S%')), 336::bigint, 'AC4: 42 sections x 8 subjects = 336 pairs are materialised');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select clock_timestamp() as t0 \gset
select count(*) as grid_rows from public.v_syllabus_variance where campus_id = :'campus_id' and subject_id in (select id from public.subject where code like 'S%') \gset
select clock_timestamp() as t1 \gset
select is(:'grid_rows'::int, 336, 'AC4: the Principal''s variance grid has 336 rows');
select ok(:'t1'::timestamptz - :'t0'::timestamptz < interval '2 seconds', 'AC4: and renders from the materialised source in under 2 seconds');

-- ── acknowledged reasons ─────────────────────────────────────────────────
select public.acknowledge_syllabus_variance(:'sec'::uuid, :'phy'::uuid, 'Schools closed for floods in the first week');
select is((select ack_reason from public.v_syllabus_variance where section_id = :'sec' and subject_id = :'phy'), 'Schools closed for floods in the first week', 'an acknowledged reason is shown with the pair');
select throws_ok(format($$ select public.acknowledge_syllabus_variance(%L, %L, ' ') $$, :'sec', :'phy'), 'REASON_REQUIRED', 'a reason is required');
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.v_syllabus_variance), 0::bigint, 'a teacher sees no variance grid');
select throws_ok(format($$ select public.acknowledge_syllabus_variance(%L, %L, 'because') $$, :'sec', :'phy'), 'FORBIDDEN', 'and cannot acknowledge');
select throws_ok($$ select public.refresh_syllabus_variance() $$, 'FORBIDDEN', 'the whole-platform refresh is not callable by a signed-in user');
select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.v_syllabus_variance), 0::bigint, 'another school sees none of these pairs');

select * from finish();
rollback;
