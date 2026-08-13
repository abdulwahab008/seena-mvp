-- pgTAP tests for FR-J08: result withheld on fee default.
--
--   AC1  dues of PKR 12,000 against a threshold of PKR 5,000 at the cut-off
--        withhold the candidate: no card is produced, the parent portal reads
--        "Result withheld — please contact the accounts office", and the
--        candidate is excluded from the rank list the parent can see.
--   AC2  the money arrives and the next sync clears the withhold with no
--        staff action at all.
--   AC3  the Principal grants a hardship release with a reason: the card
--        becomes available while the dues remain outstanding, and the
--        override is recorded with actor and reason.
--   AC4  a withheld candidate's computed marks and grades are fully visible
--        internally.
--
-- Plus the properties the acceptance criteria do not state and the module
-- depends on:
--
--   * a fee-default refusal and a DEBARMENT refusal read distinctly at the
--     same gate, because they are settled at different desks;
--   * the fee refusal quotes the amount, the cut-off and the threshold;
--   * the gate is FR-J03's, so provisional and stale still refuse;
--   * a concession clears a withhold with no special case;
--   * the sync will not re-open a hardship release while the dues stand;
--   * only the Principal releases, a reason is compulsory, and the actor is
--     recorded;
--   * one open withhold per candidate per term, whatever the reason;
--   * a null-tenant caller is refused rather than silently reading every
--     balance as zero;
--   * withholds are tenant-isolated, cannot be written directly, and the
--     table cannot be truncated.
begin;
select plan(57);

select public.provision_tenant('test-hold-co', 'Hold Co', 'owner@holdco.test');
select id as tenant_id from public.tenant where slug = 'test-hold-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select public.provision_tenant('test-hold-rival', 'Hold Rival', 'owner@holdrival.test');
select id as rival_id from public.tenant where slug = 'test-hold-rival' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@holdco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Hold Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@holdco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@holdco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Tahira Aziz');

select gen_random_uuid() as clerk_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'clerk_uid', 'accounts@holdco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'clerk_uid', :'tenant_id', 'accountant', 'Accounts Clerk');

select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'rival_uid', 'owner@holdrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');

select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_subject('PHY', 'Physics', 'طبیعیات') as subj_phy \gset
select public.create_subject('MTH', 'Maths', 'ریاضی')     as subj_mth \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_phy', 6::smallint) as cs_phy \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_mth', 8::smallint) as cs_mth \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'A', 40) as sec_a \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'FINAL', 'Final Term', 1::smallint, 100.00) as term_f \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _act_terms \gset
select public.upsert_exam_subject(:'term_f', :'cs_phy', '[{"component":"theory","max_marks":300,"pass_marks":0}]'::jsonb) as es_phy \gset
select public.upsert_exam_subject(:'term_f', :'cs_mth', '[{"component":"theory","max_marks":200,"pass_marks":0}]'::jsonb) as es_mth \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.save_grading_scheme(
  'FBISE'::public.board, 'FBISE 2025', date '2000-01-01',
  '[{"grade_label":"A1","min_pct":80,"max_pct":100,"gpa_point":4.00},
    {"grade_label":"A", "min_pct":70,"max_pct":79.99,"gpa_point":3.70},
    {"grade_label":"B", "min_pct":60,"max_pct":69.99,"gpa_point":3.30},
    {"grade_label":"C", "min_pct":50,"max_pct":59.99,"gpa_point":3.00},
    {"grade_label":"D", "min_pct":40,"max_pct":49.99,"gpa_point":2.50},
    {"grade_label":"E", "min_pct":33,"max_pct":39.99,"gpa_point":2.00},
    {"grade_label":"F", "min_pct":0, "max_pct":32.99,"gpa_point":0.00,"is_pass":false}]'::jsonb
) as fbise \gset
select public.activate_grading_scheme(:'fbise') as _act_scheme \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

-- Four candidates, one per situation the FR distinguishes:
--   Ayesha    owes 12,000 against a 5,000 threshold — AC1's defaulter.
--   Bilal     owes nothing.
--   Chandni   owes 12,000 too, and is the one the Principal releases (AC3).
--   Danish    owes nothing and is DEBARRED, so the gate must refuse him for a
--             completely different reason and say so.
select public.create_student(:'campus_a', 'Ayesha Noor', '2011-01-01'::date, 'female') as st_ayesha \gset
select public.create_student(:'campus_a', 'Bilal Ahmed', '2011-02-01'::date, 'male')   as st_bilal \gset
select public.create_student(:'campus_a', 'Chandni Rao', '2011-03-01'::date, 'female') as st_chandni \gset
select public.create_student(:'campus_a', 'Danish Ali',  '2011-04-01'::date, 'male')   as st_danish \gset

select public.enrol_student(:'sec_a', :'st_ayesha')  as enr_ayesha \gset
select public.enrol_student(:'sec_a', :'st_bilal')   as enr_bilal \gset
select public.enrol_student(:'sec_a', :'st_chandni') as enr_chandni \gset
select public.enrol_student(:'sec_a', :'st_danish')  as enr_danish \gset

select public.fn_find_or_create_guardian(p_name_en => 'Ayesha Mother', p_phone_e164 => '+923005550061') as g_ayesha \gset
select public.link_guardian(:'st_ayesha'::uuid, :'g_ayesha'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
select gen_random_uuid() as parent_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'parent_uid', 'mother@holdco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'parent_uid', :'tenant_id', 'parent', 'Ayesha Mother');
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g_ayesha'::uuid;
set local role authenticated;

-- ── The money ──────────────────────────────────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
-- PKR 12,000 = 1,200,000 paisa. Money is paisa as bigint (FR-K24).
select public.post_ledger_entry(:'enr_ayesha'::uuid,  'charge'::public.fee_ledger_entry_type, 1200000::bigint, 'debit'::public.fee_ledger_direction) as _l1 \gset
select public.post_ledger_entry(:'enr_chandni'::uuid, 'charge'::public.fee_ledger_entry_type, 1200000::bigint, 'debit'::public.fee_ledger_direction) as _l2 \gset
-- Bilal and Danish are charged and pay in full, so they carry no balance.
select public.post_ledger_entry(:'enr_bilal'::uuid,  'charge'::public.fee_ledger_entry_type,  1200000::bigint, 'debit'::public.fee_ledger_direction)  as _l3 \gset
select public.post_ledger_entry(:'enr_bilal'::uuid,  'payment'::public.fee_ledger_entry_type, 1200000::bigint, 'credit'::public.fee_ledger_direction) as _l4 \gset
select public.post_ledger_entry(:'enr_danish'::uuid, 'charge'::public.fee_ledger_entry_type,  1200000::bigint, 'debit'::public.fee_ledger_direction)  as _l5 \gset
select public.post_ledger_entry(:'enr_danish'::uuid, 'payment'::public.fee_ledger_entry_type, 1200000::bigint, 'credit'::public.fee_ledger_direction) as _l6 \gset

select is(
  app.fn_withhold_threshold_paisa(:'campus_a'::uuid),
  0::bigint,
  'a campus that has never been configured has a threshold of 0 — any outstanding balance is a default'
);

-- AC1's threshold: PKR 5,000.
select public.set_result_withhold_threshold(:'campus_a'::uuid, 500000::bigint);
select is(
  app.fn_withhold_threshold_paisa(:'campus_a'::uuid),
  500000::bigint,
  'AC1: the threshold is a stored campus setting, in paisa'
);

-- ── The marks ──────────────────────────────────────────────────────────
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.set_exam_attendance(:'es_phy', :'enr_danish', 'debarred', 'disciplinary') as _deb \gset

select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_phy', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 240),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 220),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 200)
))) as _mp \gset
select public.fn_upsert_marks(jsonb_build_object('exam_subject_id', :'es_mth', 'marks', jsonb_build_array(
  jsonb_build_object('enrolment_id', :'enr_ayesha',  'component', 'theory', 'marks_obtained', 160),
  jsonb_build_object('enrolment_id', :'enr_bilal',   'component', 'theory', 'marks_obtained', 150),
  jsonb_build_object('enrolment_id', :'enr_chandni', 'component', 'theory', 'marks_obtained', 140),
  jsonb_build_object('enrolment_id', :'enr_danish',  'component', 'theory', 'marks_obtained', 130)
))) as _mm \gset
select public.fn_approve_marks(:'es_phy', :'sec_a') as _ap1 \gset
select public.fn_approve_marks(:'es_mth', :'sec_a') as _ap2 \gset

select is(
  (select count(*)::int from public.result_position where exam_term_id = :'term_f'),
  4,
  'the class is signed off and every candidate has a position row before anything is withheld'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The gate refuses for the right reason, in the right words
-- ═══════════════════════════════════════════════════════════════════════

-- Nothing has been synced yet: the balance exists but no withhold does.
select lives_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_ayesha', :'term_f'),
  'an unsynced defaulter is not withheld — a withhold is a stored decision, not a balance read at print time'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select public.fn_sync_fee_withholds(:'term_f'::uuid) as sync1 \gset

select is(
  (:'sync1'::jsonb ->> 'opened')::int,
  2,
  'AC1: the sync opens a withhold for each candidate over the threshold, and only those'
);
select is(
  (:'sync1'::jsonb ->> 'threshold_paisa')::bigint,
  500000::bigint,
  'and reports the threshold it measured against'
);
select is(
  (select amount_outstanding_paisa from public.result_withhold where enrolment_id = :'enr_ayesha' and released_at is null),
  1200000::bigint,
  'AC1: PKR 12,000 outstanding is frozen onto the row in paisa'
);
select is(
  (select reason::text from public.result_withhold where enrolment_id = :'enr_ayesha' and released_at is null),
  'fee_default',
  'and the reason is fee_default'
);
select is(
  (select cutoff_date from public.result_withhold where enrolment_id = :'enr_ayesha' and released_at is null),
  current_date,
  'AC1: the cut-off the balance was measured to is stored, so "as at" is answerable later'
);

select throws_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_ayesha', :'term_f'),
  '23514',
  'result withheld — outstanding dues of PKR 12,000 as at ' || to_char(current_date, 'DD Mon YYYY') || ' exceed the PKR 5,000 threshold',
  'AC1: the refusal quotes the amount, the cut-off and the threshold, in rupees'
);

-- The distinction the whole design turns on.
select throws_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_danish', :'term_f'),
  '23514',
  'result withheld — the candidate is debarred in this term',
  'a debarred candidate is refused for DEBARMENT, not for money — the two are settled at different desks'
);
select lives_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_bilal', :'term_f'),
  'and a candidate who owes nothing and sat the papers prints'
);

-- FR-J03's gate, extended rather than duplicated.
select throws_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_ayesha'),
  '23514',
  'result withheld for Final Term — outstanding dues of PKR 12,000 as at ' || to_char(current_date, 'DD Mon YYYY') || ' exceed the PKR 5,000 threshold',
  'the annual gate refuses too, naming the term the withhold is on'
);
select throws_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_danish'),
  '23514',
  'result withheld — the candidate is debarred in this session',
  'FR-J03 recorded debarment on annual_result.is_blocked and never refused to print it; now it does'
);
select lives_ok(
  format($$select public.fn_assert_annual_result_publishable(%L, %L)$$, :'session_a', :'enr_bilal'),
  'and FR-J03''s provisional and stale checks still let a clean candidate through'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: withholding blocks disclosure, not computation
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select is(
  (select count(*)::int from public.subject_result where enrolment_id = :'enr_ayesha' and exam_term_id = :'term_f'),
  2,
  'AC4: the exam office still reads both of a withheld candidate''s subject results'
);
select is(
  (select grade_label from public.subject_result
    where enrolment_id = :'enr_ayesha' and subject_id = :'subj_phy'),
  'A1',
  'AC4: with the grade still on them — the marks were never touched'
);
select is(
  (select rank_in_section from public.result_position where enrolment_id = :'enr_ayesha'),
  1,
  'AC4: and the internal merit list still ranks them, so the gazette is intact'
);
select is(
  (select is_ranked from public.result_position where enrolment_id = :'enr_ayesha'),
  true,
  'a fee withhold is not FR-J05''s exclusion — removing them would renumber the whole class the day one parent paid'
);

select is(
  ((public.fn_withhold_sheet(:'term_f', :'class9')) -> 'candidates' -> 0 ->> 'is_withheld')::boolean,
  true,
  'AC4: the staff sheet says plainly who is withheld'
);
select is(
  (select (c ->> 'balance_paisa')::bigint
     from jsonb_array_elements((public.fn_withhold_sheet(:'term_f', :'class9')) -> 'candidates') c
    where (c ->> 'enrolment_id')::uuid = :'enr_ayesha'::uuid),
  1200000::bigint,
  'AC4: and shows the number, because staff are exactly who may see it'
);
select is(
  (select (c ->> 'is_debarred')::boolean
     from jsonb_array_elements((public.fn_withhold_sheet(:'term_f', :'class9')) -> 'candidates') c
    where (c ->> 'enrolment_id')::uuid = :'enr_danish'::uuid),
  true,
  'and separates a debarment from a money hold on the same sheet'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC1's parent half: the portal sentence, and the vanished rank
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (public.fn_portal_term_result(:'enr_ayesha', :'term_f')) ->> 'message',
  'Result withheld — please contact the accounts office',
  'AC1: the parent portal shows the FR''s sentence, word for word'
);
select is(
  jsonb_array_length((public.fn_portal_term_result(:'enr_ayesha', :'term_f')) -> 'subjects'),
  0,
  'AC1: and no marks travel with it'
);
select is(
  (select count(*)::int from public.subject_result where enrolment_id = :'enr_ayesha'),
  0,
  'AC1: the parent''s own RLS drops the subject results too, not just the portal function'
);
select is(
  (select count(*)::int from public.result_position where enrolment_id = :'enr_ayesha'),
  0,
  'AC1: and the candidate is excluded from the rank list the parent can read'
);
select is(
  (select count(*)::int from public.result_withhold),
  0,
  'a parent is never shown the withhold row itself — the amount outstanding is an accounts-office conversation'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: the Principal's hardship release
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select id as hold_chandni from public.result_withhold
 where enrolment_id = :'enr_chandni' and released_at is null \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select throws_ok(
  format($$select public.release_result_withhold(%L, 'father lost his job')$$, :'hold_chandni'),
  '42501',
  'FORBIDDEN',
  'the Accountant raises the debt and does not get to forgive its consequence'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$select public.release_result_withhold(%L, '   ')$$, :'hold_chandni'),
  '23514',
  'a hardship release needs a reason',
  'AC3: an override with no reason is an unexplained disappearance, not an override'
);

select public.release_result_withhold(:'hold_chandni'::uuid, 'Hardship: father hospitalised, dues rescheduled to September');

select is(
  (select release_kind::text from public.result_withhold where id = :'hold_chandni'),
  'hardship',
  'AC3: the release records that it was hardship rather than payment'
);
select is(
  (select released_by from public.result_withhold where id = :'hold_chandni'),
  :'principal_uid'::uuid,
  'AC3: with the actor who granted it'
);
select is(
  (select release_reason from public.result_withhold where id = :'hold_chandni'),
  'Hardship: father hospitalised, dues rescheduled to September',
  'AC3: and their reason'
);
select is(
  (select greatest(public.outstanding_balance_as_of(:'enr_chandni'::uuid, clock_timestamp()), 0)),
  1200000::bigint,
  'AC3: while the dues remain outstanding — a release is not a payment'
);
select lives_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_chandni', :'term_f'),
  'AC3: and the report card becomes available'
);

select is(
  (select count(*)::int from public.audit_log
    where table_name = 'result_withhold' and row_id = :'hold_chandni'::uuid and action = 'update'),
  1,
  'AC3: the override is on the tamper-evident audit chain as well as on the row'
);

-- The tick that would otherwise undo AC3.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select public.fn_sync_fee_withholds(:'term_f'::uuid) as sync2 \gset
select is(
  (:'sync2'::jsonb ->> 'opened')::int,
  0,
  'AC3: the next sync does NOT re-open a hardship release, or the override would last one cron tick'
);
select lives_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_chandni', :'term_f'),
  'AC3: so the card is still available ten minutes later'
);
select is(
  (:'sync2'::jsonb ->> 'refreshed')::int,
  1,
  'and the still-open withhold has its outstanding figure refreshed rather than duplicated'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the money arrives
-- ═══════════════════════════════════════════════════════════════════════

-- Part payment down to exactly the threshold: 12,000 - 7,000 = 5,000, which
-- is NOT above 5,000. The boundary is deliberately the one the FR words as
-- "above the configured threshold".
select public.post_ledger_entry(:'enr_ayesha'::uuid, 'payment'::public.fee_ledger_entry_type, 700000::bigint, 'credit'::public.fee_ledger_direction) as _pay \gset
select public.fn_sync_fee_withholds(:'term_f'::uuid) as sync3 \gset

select is(
  (:'sync3'::jsonb ->> 'released')::int,
  1,
  'AC2: the sync clears the withhold with no staff action at all'
);
select is(
  (select release_kind::text from public.result_withhold
    where enrolment_id = :'enr_ayesha' order by raised_at desc limit 1),
  'paid',
  'AC2: recorded as paid, which is what keeps it distinct from a hardship override'
);
select is(
  (select count(*)::int from public.result_withhold
    where enrolment_id = :'enr_ayesha' and released_at is null),
  0,
  'AC2: and nothing is open against that candidate any more'
);
select lives_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_ayesha', :'term_f'),
  'AC2: so the card prints, at a balance exactly ON the threshold rather than above it'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'parent_uid')::text,
  true
);
select is(
  (select count(*)::int from public.subject_result where enrolment_id = :'enr_ayesha'),
  2,
  'AC2: and the parent can see the result again, through the same RLS that hid it'
);
select is(
  (select count(*)::int from public.result_position where enrolment_id = :'enr_ayesha'),
  1,
  'AC2: position included'
);

-- A concession is a credit, so it clears a withhold through the same
-- arithmetic with no special case anywhere.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select public.post_ledger_entry(:'enr_ayesha'::uuid, 'charge'::public.fee_ledger_entry_type, 800000::bigint, 'debit'::public.fee_ledger_direction) as _c1 \gset
select public.fn_sync_fee_withholds(:'term_f'::uuid) as sync4 \gset
select is(
  (:'sync4'::jsonb ->> 'opened')::int,
  1,
  'a new charge takes the balance over the threshold and the sync withholds again'
);
select public.post_ledger_entry(:'enr_ayesha'::uuid, 'concession'::public.fee_ledger_entry_type, 800000::bigint, 'credit'::public.fee_ledger_direction) as _c2 \gset
select public.fn_sync_fee_withholds(:'term_f'::uuid) as sync5 \gset
select is(
  (:'sync5'::jsonb ->> 'released')::int,
  1,
  'and a concession clears it with no special case — a waiver is already inside the balance'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The manual holds, and one open withhold per candidate per term
-- ═══════════════════════════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$select public.raise_result_withhold(%L, %L, 'fee_default', 'because I say so')$$, :'enr_bilal', :'term_f'),
  '23514',
  'a fee-default withhold is opened by the sync, not by hand',
  'a hand-typed fee hold would be released by the next sync, which reads as the system losing it'
);
select throws_ok(
  format($$select public.raise_result_withhold(%L, %L, 'discipline', '  ')$$, :'enr_bilal', :'term_f'),
  '23514',
  'WITHHOLD_NOTE_REQUIRED',
  'a manual hold has to say why'
);

select public.raise_result_withhold(:'enr_bilal'::uuid, :'term_f'::uuid, 'discipline'::public.result_withhold_reason,
                                    'Pending disciplinary committee outcome') as hold_bilal \gset
select throws_ok(
  format($$select public.fn_assert_result_disclosable(%L, %L)$$, :'enr_bilal', :'term_f'),
  '23514',
  'result withheld — a discipline hold is open on this candidate (Pending disciplinary committee outcome)',
  'a discipline hold reads as a discipline hold, and carries its note'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'clerk_uid')::text,
  true
);
select public.post_ledger_entry(:'enr_bilal'::uuid, 'charge'::public.fee_ledger_entry_type, 900000::bigint, 'debit'::public.fee_ledger_direction) as _c3 \gset
select public.fn_sync_fee_withholds(:'term_f'::uuid) as sync6 \gset
select is(
  (:'sync6'::jsonb ->> 'opened')::int,
  0,
  'a candidate already under a discipline hold gets no second row — uq_withhold_open is not partitioned by reason'
);
select is(
  (select count(*)::int from public.result_withhold
    where enrolment_id = :'enr_bilal' and released_at is null),
  1,
  'and the one open hold is still the discipline one'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Refusals: the System path, other tenants, direct writes, TRUNCATE
-- ═══════════════════════════════════════════════════════════════════════

select set_config('request.jwt.claims', '', true);
select throws_ok(
  format($$select public.fn_sync_fee_withholds(%L)$$, :'term_f'),
  '42501',
  'fee withholds can only be synced by a signed-in user — the balance function is tenant-scoped',
  'a null-tenant caller is refused, because outstanding_balance_as_of() would read every balance as zero and release everything'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'sub', :'rival_uid')::text,
  true
);
select is(
  (select count(*)::int from public.result_withhold),
  0,
  'another tenant sees no withholds at all'
);
select throws_ok(
  format($$select public.fn_sync_fee_withholds(%L)$$, :'term_f'),
  '42501',
  'FORBIDDEN',
  'and cannot sync another tenant''s term'
);
select throws_ok(
  format($$select public.fn_withhold_sheet(%L, %L)$$, :'term_f', :'class9'),
  '42501',
  'FORBIDDEN',
  'nor read its sheet'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
-- withhold_no_direct_dml is USING false, so this matches no rows rather than
-- raising — which is how Postgres denies an UPDATE through RLS. The property
-- being asserted is that the row did not move.
update public.result_withhold set released_at = now(), release_kind = 'paid' where id = :'hold_bilal';
select is(
  (select released_at from public.result_withhold where id = :'hold_bilal'),
  null::timestamptz,
  'a withhold cannot be released by a direct UPDATE — the release audit trail is unavoidable, not conventional'
);
select throws_ok(
  $$truncate public.result_withhold$$,
  '42501',
  null,
  'and the table cannot be truncated: the hardship releases in it are reconstructible from nothing'
);

select * from finish();
rollback;
