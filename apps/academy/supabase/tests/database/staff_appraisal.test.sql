-- pgTAP tests for FR-D14: staff appraisal cycle and scoring.
begin;
select plan(35);

select public.provision_tenant('test-appr-co', 'Appraisal Co', 'owner@appr.test');
select id as tenant_id from public.tenant where slug = 'test-appr-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-appr-other', 'Other Appr Co', 'owner@otherappr.test');
select id as other_tenant_id from public.tenant where slug = 'test-appr-other' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as hr_uid \gset
select gen_random_uuid() as prin_uid \gset
select gen_random_uuid() as t1_uid \gset
select gen_random_uuid() as t2_uid \gset
select gen_random_uuid() as t3_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'owner_uid', 'o@appr.test', 'authenticated', 'authenticated', 'x'), (:'hr_uid', 'h@appr.test', 'authenticated', 'authenticated', 'x'),
  (:'prin_uid', 'p@appr.test', 'authenticated', 'authenticated', 'x'), (:'t1_uid', 't1@appr.test', 'authenticated', 'authenticated', 'x'),
  (:'t2_uid', 't2@appr.test', 'authenticated', 'authenticated', 'x'), (:'t3_uid', 't3@appr.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'hr_uid', :'tenant_id', 'hr_manager', 'HR'), (:'prin_uid', :'tenant_id', 'principal', 'Principal'),
  (:'t1_uid', :'tenant_id', 'subject_teacher', 'Teacher One'), (:'t2_uid', :'tenant_id', 'subject_teacher', 'Teacher Two'), (:'t3_uid', :'tenant_id', 'subject_teacher', 'New Joiner');
insert into public.user_campus (user_id, tenant_id, campus_id) values (:'prin_uid', :'tenant_id', :'campus_id');
insert into public.staff (tenant_id, campus_id, user_id, employee_code, cnic, gender, doj, full_name) values
  (:'tenant_id', :'campus_id', :'t1_uid', 'AP-1', '42101-7777777-1', 'female', '2020-01-01', 'Teacher One'),
  (:'tenant_id', :'campus_id', :'t2_uid', 'AP-2', '42101-7777777-2', 'male', '2021-06-01', 'Teacher Two'),
  (:'tenant_id', :'campus_id', :'t3_uid', 'AP-3', '42101-7777777-3', 'female', '2026-08-16', 'New Joiner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.create_appraisal_cycle(:'session_id'::uuid, '2026 annual appraisal', '2026-04-01'::date, '2026-09-30'::date, 90::smallint) as cyc \gset

-- ── AC1: weights must sum to 100 before a cycle can be published ─────────
select public.set_cycle_competencies(:'cyc'::uuid, '[{"name":"Subject knowledge","weight_pct":25},{"name":"Planning","weight_pct":20},{"name":"Classroom","weight_pct":20},{"name":"Assessment","weight_pct":15},{"name":"Professionalism","weight_pct":10},{"name":"Communication","weight_pct":9}]'::jsonb);
select throws_ok(format($$ select public.publish_appraisal_cycle(%L::uuid) $$, :'cyc'), '23514', 'WEIGHTS_NOT_100: weights sum to 99.00', 'AC1: weights summing to 99 cannot be published, and the error says what they sum to');
select public.set_cycle_competencies(:'cyc'::uuid, '[{"name":"Subject knowledge","weight_pct":25},{"name":"Planning","weight_pct":20},{"name":"Classroom","weight_pct":20},{"name":"Assessment","weight_pct":15},{"name":"Professionalism","weight_pct":10},{"name":"Communication","weight_pct":10}]'::jsonb);
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.publish_appraisal_cycle(%L::uuid) $$, :'cyc'), 'FORBIDDEN', 'a Principal cannot publish a cycle');
select set_config('request.jwt.claims', json_build_object('sub', :'hr_uid', 'tenant_id', :'tenant_id', 'app_role', 'hr_manager', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is(public.publish_appraisal_cycle(:'cyc'::uuid), 2, 'AC1: six weights summing to 100 publish, opening an appraisal for each of the 2 eligible staff');

-- ── AC4: 45 days of service at cycle close with a 90 day minimum => excluded ──
select is((select count(*) from public.appraisal a join public.staff s on s.id = a.staff_id where s.employee_code = 'AP-3'), 0::bigint, 'AC4: the 45-day joiner has no appraisal in the cycle');
select is((public.appraisal_cycle_report(:'cyc'::uuid) ->> 'eligible')::int, 2, 'AC4: and is not counted in the aggregate report');
select is((public.appraisal_cycle_report(:'cyc'::uuid) ->> 'excluded_count')::int, 1, 'AC4: the report lists them as excluded');
select is(((public.appraisal_cycle_report(:'cyc'::uuid) -> 'excluded' -> 0) ->> 'service_days')::int, 45, 'AC4: with their 45 days of service');
select is((select jsonb_array_length(template_snapshot) from public.appraisal limit 1), 6, 'every appraisal carries its own copy of the 6 weighted competencies');
select is((select rater_id from public.appraisal limit 1), :'prin_uid'::uuid, 'the campus Principal is the default rater');
select throws_ok(format($$ select public.set_cycle_competencies(%L::uuid, '[]'::jsonb) $$, :'cyc'), 'CYCLE_TEMPLATE_FROZEN', 'a published template can no longer be edited');
select throws_ok(format($$ select public.publish_appraisal_cycle(%L::uuid) $$, :'cyc'), 'CYCLE_ALREADY_PUBLISHED', 'and cannot be published twice');
reset role;
select id as ap1 from public.appraisal where staff_id = (select id from public.staff where employee_code = 'AP-1' and tenant_id = :'tenant_id') \gset
select id as ap2 from public.appraisal where staff_id = (select id from public.staff where employee_code = 'AP-2' and tenant_id = :'tenant_id') \gset
select jsonb_agg(jsonb_build_object('competency_id', t ->> 'id', 'rating', 4)) as all4 from public.appraisal a, jsonb_array_elements(a.template_snapshot) t where a.id = :'ap1' \gset
select jsonb_agg(jsonb_build_object('competency_id', t ->> 'id', 'rating', (array[5, 3, 4, 2, 1, 5])[ord])) as mixed from public.appraisal a, jsonb_array_elements(a.template_snapshot) with ordinality x(t, ord) where a.id = :'ap2' \gset
select jsonb_agg(jsonb_build_object('competency_id', t ->> 'id', 'rating', 5)) as five_of_six from public.appraisal a, jsonb_array_elements(a.template_snapshot) with ordinality x(t, ord) where a.id = :'ap2' and ord <= 5 \gset

-- ── AC2: nothing leaks before release ────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.appraisal), 0::bigint, 'AC2: before release the appraisee''s own table query returns no row');
select is(public.get_my_appraisal(:'cyc'::uuid) ->> 'status', 'in_progress', 'AC2: get_my_appraisal reports in_progress');
select ok(public.get_my_appraisal(:'cyc'::uuid) -> 'scores' = 'null'::jsonb and public.get_my_appraisal(:'cyc'::uuid) -> 'total_score' = 'null'::jsonb, 'AC2: and returns no scores');
select throws_ok(format($$ select public.save_appraisal_scores(%L::uuid, %L::jsonb) $$, :'ap1', :'all4'), 'FORBIDDEN', 'the appraisee cannot score themselves');

-- ── scoring: 25/20/20/15/10/10 all rated 4 => 80.00 ──────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'prin_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.save_appraisal_scores(%L::uuid, '[{"competency_id":"00000000-0000-0000-0000-000000000000","rating":4}]'::jsonb) $$, :'ap1'), 'COMPETENCY_NOT_IN_APPRAISAL', 'a rating must be for a competency of this appraisal');
select throws_ok(format($$ select public.save_appraisal_scores(%L::uuid, %L::jsonb) $$, :'ap1', replace(:'all4', '"rating": 4', '"rating": 6')), 'RATING_OUT_OF_RANGE', 'ratings are 1 to 5');
select public.save_appraisal_scores(:'ap1'::uuid, :'all4'::jsonb);
select is((select count(*) from public.appraisal_score where appraisal_id = :'ap1'::uuid), 6::bigint, 'the rater saves six ratings');
select is(public.release_appraisal(:'ap1'::uuid), 80.00::numeric, 'AC1: six competencies rated 4 of 5 score 80.00 of 100');
select throws_ok(format($$ select public.save_appraisal_scores(%L::uuid, %L::jsonb) $$, :'ap1', :'all4'), 'APPRAISAL_NOT_EDITABLE', 'a released appraisal can no longer be rescored');
select public.save_appraisal_scores(:'ap2'::uuid, :'five_of_six'::jsonb);
select throws_ok(format($$ select public.release_appraisal(%L::uuid) $$, :'ap2'), 'SCORES_INCOMPLETE', 'an appraisal with an unrated competency cannot be released');
select public.save_appraisal_scores(:'ap2'::uuid, :'mixed'::jsonb);
select is(public.release_appraisal(:'ap2'::uuid), 71.00::numeric, 'a mixed set 5,3,4,2,1,5 scores 25+12+16+6+2+10 = 71.00');

-- ── after release the appraisee sees the scores; AC3: dispute ────────────
select set_config('request.jwt.claims', json_build_object('sub', :'t1_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*) from public.appraisal), 1::bigint, 'after release the appraisee reads their own appraisal row (and only theirs)');
select is(jsonb_array_length(public.get_my_appraisal(:'cyc'::uuid) -> 'scores'), 6, 'and now gets the six scores');
select is((public.get_my_appraisal(:'cyc'::uuid) ->> 'total_score')::numeric, 80.00::numeric, 'with the total');
select public.acknowledge_appraisal(:'ap1'::uuid);
select is((select status::text from public.appraisal where id = :'ap1'::uuid), 'final', 'acknowledging finalises the appraisal');
select ok((select acknowledged_at is not null from public.appraisal where id = :'ap1'::uuid), 'with the acknowledgement time stamped');
select set_config('request.jwt.claims', json_build_object('sub', :'t2_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$ select public.dispute_appraisal(%L::uuid, %L) $$, :'ap2', repeat('x', 2001)), 'COMMENT_TOO_LONG', 'AC3: a response over 2000 characters is refused');
select public.dispute_appraisal(:'ap2'::uuid, repeat('y', 2000));
select is((select status::text from public.appraisal where id = :'ap2'::uuid), 'awaiting_acknowledgement', 'AC3: a 2000-character dispute is stored and the appraisal stays awaiting acknowledgement');
select throws_ok(format($$ select public.acknowledge_appraisal(%L::uuid) $$, :'ap1'), 'APPRAISAL_NOT_FOUND', 'one appraisee cannot act on another''s appraisal');

select set_config('request.jwt.claims', json_build_object('sub', :'owner_uid', 'tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select char_length(appraisee_comment) from public.appraisal where id = :'ap2'::uuid), 2000, 'AC3: the Owner can read the appraisee''s response');
select public.finalise_appraisal(:'ap2'::uuid);
select is((select status::text from public.appraisal where id = :'ap2'::uuid), 'final', 'the Owner closes a disputed appraisal after hearing it');
select is((public.appraisal_cycle_report(:'cyc'::uuid) ->> 'average_score')::numeric, 75.50::numeric, 'the cycle report averages the two scored appraisals (80 and 71)');

select set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*) from public.appraisal), 0::bigint, 'another school sees none');

-- ── the deferred trg_weights_sum_100 (last: it leaves a stray row behind) ──
reset role;
set constraints trg_weights_sum_100 immediate; -- flush the events queued while the draft template was built
set constraints trg_weights_sum_100 deferred;
alter table public.appraisal_competency disable trigger trg_appraisal_competency_frozen;
insert into public.appraisal_competency (cycle_id, tenant_id, name, weight_pct) values (:'cyc', :'tenant_id', 'Extra', 5);
select throws_ok($$ set constraints trg_weights_sum_100 immediate $$, '23514', null, 'trg_weights_sum_100 refuses a published cycle whose weights no longer sum to 100');

select * from finish();
rollback;
