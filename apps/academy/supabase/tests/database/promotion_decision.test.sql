-- pgTAP tests for FR-J04: promotion and compartment decision.
--
--   AC1  rule "detain on 3+, compartment on 1-2, promote at 40% with no
--        failures": a student failing only Maths at 55% -> Compartment, Maths
--        listed.
--   AC2  a student failing 3 subjects -> Detained, and the next-session
--        enrolment into a higher class is blocked.
--   AC3  a withheld result -> Pending, excluded from the promotion batch.
--   AC4  a Principal overriding Detained -> Promoted on Trial stores actor and
--        reason; the parent-facing report card shows only the final decision.
--
-- Plus: a configurable (class-specific) rule changes outcomes, an override
-- survives re-evaluation, the hand-off conflict is raised in the same
-- transaction when a promoted student's result flips after roll-over, and the
-- table is invisible to other roles and other schools.
begin;
select plan(38);

select public.provision_tenant('test-promo-co', 'Promo Co', 'owner@promoco.test');
select id as tenant_id from public.tenant where slug = 'test-promo-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session0 from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset
select public.provision_tenant('test-promo-rival', 'Promo Rival', 'owner@promorival.test');
select id as rival_id from public.tenant where slug = 'test-promo-rival' \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as ec_uid \gset
select gen_random_uuid() as principal_uid \gset
select gen_random_uuid() as clerk_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@promoco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'ec_uid', 'e@promoco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'principal_uid', 'p@promoco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'clerk_uid', 'c@promoco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@promorival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal'),
  (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz'), (:'clerk_uid', :'tenant_id', 'accountant', 'Clerk'),
  (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'principal_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);

select public.create_academic_session(:'campus_id'::uuid, 'next', (current_date + interval '1 year')::date, (current_date + interval '2 years' - interval '1 day')::date) as next_session \gset
select public.create_section(:'campus_id'::uuid, :'session0'::uuid, :'class9'::uuid, 'A', 40) as sec9 \gset
select public.create_section(:'campus_id'::uuid, :'next_session'::uuid, :'class10'::uuid, 'A', 40) as sec10 \gset
select public.create_section(:'campus_id'::uuid, :'next_session'::uuid, :'class9'::uuid, 'A', 40) as sec9_next \gset
select public.create_subject('MTH', 'Maths', 'ریاضی') as s_mth \gset
select public.create_subject('PHY', 'Physics', 'طبیعیات') as s_phy \gset
select public.create_subject('ISL', 'Islamiat', 'اسلامیات') as s_isl \gset
select public.create_subject('ENG', 'English', 'انگریزی') as s_eng \gset
select public.upsert_exam_term(:'campus_id'::uuid, :'session0'::uuid, 'FINAL', 'Final Term', 1::smallint, 100.00) as term_final \gset

select public.create_student(:'campus_id'::uuid, 'Ayesha Noor', '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_id'::uuid, 'Bilal Ahmed', '2011-02-01'::date, 'male') as st_bilal \gset
select public.create_student(:'campus_id'::uuid, 'Chandni Rao', '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_id'::uuid, 'Danish Ali', '2011-04-01'::date, 'male') as st_danish \gset
select public.create_student(:'campus_id'::uuid, 'Emaan Zafar', '2011-05-01'::date, 'female') as st_emaan \gset
select public.create_student(:'campus_id'::uuid, 'Farhan Qazi', '2011-06-01'::date, 'male') as st_farhan \gset
select public.enrol_student(:'sec9'::uuid, :'st_ayesha'::uuid) as e_ayesha \gset
select public.enrol_student(:'sec9'::uuid, :'st_bilal'::uuid) as e_bilal \gset
select public.enrol_student(:'sec9'::uuid, :'st_chandni'::uuid) as e_chandni \gset
select public.enrol_student(:'sec9'::uuid, :'st_danish'::uuid) as e_danish \gset
select public.enrol_student(:'sec9'::uuid, :'st_emaan'::uuid) as e_emaan \gset
select public.enrol_student(:'sec9'::uuid, :'st_farhan'::uuid) as e_farhan \gset

-- Annual results are FR-J03's output; the fixture writes them as the system
-- would have, one row per subject. (is_pass false = failed the subject.)
reset role;
create temp table _ar (enr uuid, subj uuid, pct numeric, pass boolean, st text default 'final');
insert into _ar (enr, subj, pct, pass) values
  -- Ayesha: fails Maths only. Aggregate (35+70+60+55)/4 = 55.
  (:'e_ayesha', :'s_mth', 35, false), (:'e_ayesha', :'s_phy', 70, true), (:'e_ayesha', :'s_isl', 60, true), (:'e_ayesha', :'s_eng', 55, true),
  -- Bilal: fails three subjects.
  (:'e_bilal', :'s_mth', 20, false), (:'e_bilal', :'s_phy', 25, false), (:'e_bilal', :'s_isl', 30, false), (:'e_bilal', :'s_eng', 60, true),
  -- Chandni: clean, but her result is withheld.
  (:'e_chandni', :'s_mth', 70, true), (:'e_chandni', :'s_phy', 70, true), (:'e_chandni', :'s_isl', 70, true), (:'e_chandni', :'s_eng', 70, true),
  -- Danish: clean pass at 70.
  (:'e_danish', :'s_mth', 70, true), (:'e_danish', :'s_phy', 70, true), (:'e_danish', :'s_isl', 70, true), (:'e_danish', :'s_eng', 70, true),
  -- Emaan: no failures but the aggregate is 35 (a school whose pass mark is 33).
  (:'e_emaan', :'s_mth', 35, true), (:'e_emaan', :'s_phy', 35, true), (:'e_emaan', :'s_isl', 35, true), (:'e_emaan', :'s_eng', 35, true);
-- Farhan: a counting term is still being marked.
insert into _ar (enr, subj, pct, pass, st) values (:'e_farhan', :'s_mth', 60, true, 'provisional');
insert into public.annual_result (tenant_id, campus_id, session_id, class_level_id, section_id, enrolment_id, subject_id,
                                  weighted_pct, is_pass, status, terms_counted, terms_total, prorated_terms, is_blocked)
select :'tenant_id', :'campus_id', :'session0', :'class9', :'sec9', enr, subj, pct, pass, st::public.annual_result_status, 1, 1, 0, false from _ar;
insert into public.result_withhold (tenant_id, campus_id, exam_term_id, enrolment_id, reason, cutoff_date)
values (:'tenant_id', :'campus_id', :'term_final', :'e_chandni', 'discipline', current_date);

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);

-- ── AC1-AC3: the default rule (40 / 2 / 0), nothing configured ─────────────
select is((public.fn_evaluate_promotion(:'session0'::uuid, :'class9'::uuid) ->> 'evaluated')::int, 6, 'the Exam Controller evaluates the whole class: six candidates');

select is((select decision::text from public.promotion_decision where enrolment_id = :'e_ayesha'), 'compartment', 'AC1: failing only Maths at a 55% aggregate is a Compartment');
select is((select failed_subjects -> 0 ->> 'subject_name' from public.promotion_decision where enrolment_id = :'e_ayesha'), 'Maths', 'AC1: and Maths is the subject listed');
select is((select jsonb_array_length(failed_subjects) from public.promotion_decision where enrolment_id = :'e_ayesha'), 1, 'AC1: and only Maths');
select is((select aggregate_pct from public.promotion_decision where enrolment_id = :'e_ayesha'), 55.00::numeric, 'the aggregate it was judged on is stored');

select is((select decision::text from public.promotion_decision where enrolment_id = :'e_bilal'), 'detained', 'AC2: failing three subjects is Detained');
select is((select decision::text from public.promotion_decision where enrolment_id = :'e_danish'), 'promoted', 'a clean 70% is Promoted');
select is((select decision::text from public.promotion_decision where enrolment_id = :'e_emaan'), 'detained', 'no failures but a 35% aggregate is below the 40% minimum: Detained');
select is((select decision::text from public.promotion_decision where enrolment_id = :'e_chandni'), 'pending', 'AC3: a withheld result is Pending');
select is((select pending_reason from public.promotion_decision where enrolment_id = :'e_chandni'), 'withheld', 'and says why');
select is((select decision::text from public.promotion_decision where enrolment_id = :'e_farhan'), 'pending', 'a provisional year is Pending too');
select is((select count(*)::int from public.promotion_decision where session_id = :'session0' and decision <> 'pending'), 4, 'AC3: the promotion batch (every decision that is not Pending) leaves the two pending candidates out');
select is((select rule_snapshot ->> 'source' from public.promotion_decision where enrolment_id = :'e_danish'), 'default', 'the rule that applied is snapshotted on the decision');

-- ── a configurable rule: class-specific wins over the default ─────────────
select throws_ok(format($$select public.save_promotion_rule(%L, %L, 40, 1::smallint, 2::smallint)$$, :'campus_id', :'class9'), 'RULE_ORDER', 'a rule cannot allow more failures for promotion than for a compartment');
select lives_ok(format($$select public.save_promotion_rule(%L, %L, 30, 2::smallint, 0::smallint)$$, :'campus_id', :'class9'), 'a class-specific rule with a 30% minimum is saved');
select public.fn_evaluate_promotion(:'session0'::uuid, :'class9'::uuid) as _re \gset
select is((select decision::text from public.promotion_decision where enrolment_id = :'e_emaan'), 'promoted', 'under the 30% rule the 35% candidate is Promoted');
select is((select rule_snapshot ->> 'source' from public.promotion_decision where enrolment_id = :'e_emaan'), 'class', 'and the snapshot records that a class rule applied');
select is((select count(*)::int from public.promotion_decision where session_id = :'session0'), 6, 're-evaluating updates in place: still one decision per candidate (uq_promotion)');

-- ── AC2: the next-session enrolment gate ──────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'principal_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$select public.enrol_student(%L, %L)$$, :'sec10', :'st_bilal'), 'PROMOTION_BLOCKED', 'AC2: a Detained student cannot be enrolled into the next class');
select throws_ok(format($$select public.enrol_student(%L, %L)$$, :'sec10', :'st_chandni'), 'PROMOTION_BLOCKED', 'and neither can a Pending one');
select lives_ok(format($$select public.enrol_student(%L, %L)$$, :'sec9_next', :'st_farhan'), 'but a held-back student can be retained in the same class');
select lives_ok(format($$select public.enrol_student(%L, %L)$$, :'sec10', :'st_ayesha'), 'a Compartment student is promoted conditionally and may be enrolled');

-- ── AC4: override ─────────────────────────────────────────────────────────
select id as bilal_decision from public.promotion_decision where enrolment_id = :'e_bilal' \gset
select set_config('request.jwt.claims', json_build_object('sub', :'ec_uid', 'tenant_id', :'tenant_id', 'app_role', 'exam_controller', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$select public.override_promotion_decision(%L, 'promoted_on_trial', 'Parents appealed')$$, :'bilal_decision'), 'FORBIDDEN', 'only a Principal can override: the Exam Controller cannot');
update public.promotion_decision set decision = 'promoted', overridden_by = :'ec_uid', overridden_at = now(), override_reason = 'sneaky' where id = :'bilal_decision';
select is((select decision::text from public.promotion_decision where id = :'bilal_decision'), 'detained', 'and a direct UPDATE by a non-Principal changes nothing (RLS)');
select set_config('request.jwt.claims', json_build_object('sub', :'principal_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select throws_ok(format($$select public.override_promotion_decision(%L, 'promoted_on_trial', '  ')$$, :'bilal_decision'), 'OVERRIDE_REASON_REQUIRED', 'an override needs a reason');
select throws_ok(format($$select public.override_promotion_decision(%L, 'pending', 'x')$$, :'bilal_decision'), 'OVERRIDE_TARGET_INVALID', 'Pending cannot be granted');
select public.override_promotion_decision(:'bilal_decision'::uuid, 'promoted_on_trial', 'Parents appealed; father posted abroad') as _ov \gset
select is((select decision::text from public.promotion_decision where id = :'bilal_decision'), 'promoted_on_trial', 'AC4: Detained is now Promoted on Trial');
select is((select overridden_by from public.promotion_decision where id = :'bilal_decision'), :'principal_uid'::uuid, 'AC4: the actor is stored');
select is((select override_reason from public.promotion_decision where id = :'bilal_decision'), 'Parents appealed; father posted abroad', 'AC4: and the reason');
select is((select system_decision::text from public.promotion_decision where id = :'bilal_decision'), 'detained', 'what the rules said is kept beside the override');
select lives_ok(format($$select public.enrol_student(%L, %L)$$, :'sec10', :'st_bilal'), 'the overridden student can now be enrolled into the next class');
select public.fn_evaluate_promotion(:'session0'::uuid, :'class9'::uuid) as _re2 \gset
select is((select decision::text from public.promotion_decision where id = :'bilal_decision'), 'promoted_on_trial', 're-evaluation keeps the Principal''s override');

-- The parent-facing report card carries the final decision and nothing else.
reset role;
select app.fn_build_report_card_payload(:'e_bilal'::uuid, :'term_final'::uuid, null)::text as card \gset
select ok(:'card'::jsonb -> 'promotion' ->> 'decision' = 'promoted_on_trial'
          and :'card' not ilike '%overrid%' and :'card' not ilike '%detained%' and :'card' not ilike '%Parents appealed%',
          'AC4: the report card shows only the final decision, not the override, its reason or the original verdict');

-- ── hand-off conflict: a result flips after roll-over ─────────────────────
-- Ayesha (Compartment) is already enrolled in Class 10. Her year is corrected
-- down to three failures; re-evaluation flags the conflict in the same step.
update public.annual_result set is_pass = false, weighted_pct = 30
 where enrolment_id = :'e_ayesha' and subject_id in (:'s_phy', :'s_isl');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'principal_uid', 'tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((public.fn_evaluate_promotion(:'session0'::uuid, :'class9'::uuid) ->> 'conflicts')::int, 1, 'a flipped result for an already-enrolled student is reported as a hand-off conflict');
select is((select handoff_conflict from public.promotion_decision where enrolment_id = :'e_ayesha'), true, 'and flagged on the decision');
select is((select decision::text from public.promotion_decision where enrolment_id = :'e_ayesha'), 'detained', 'her decision is now Detained');

-- ── visibility ────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('sub', :'clerk_uid', 'tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.promotion_decision), 0, 'an accountant does not see promotion decisions');
select set_config('request.jwt.claims', json_build_object('sub', :'rival_uid', 'tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb)::text, true);
select is((select count(*)::int from public.promotion_decision), 0, 'another school sees none');

select * from finish();
rollback;
