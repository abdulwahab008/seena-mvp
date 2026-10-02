-- pgTAP tests for FR-I01: exam term definition and weightage.
--
-- Every control this FR ships is a database control, so all four ACs are
-- tested here:
--
--   AC1  the 25/15/0/60 set of the acceptance criteria activates, and all
--        four terms — including the 0% Pre-Board — become selectable.
--   AC2  the 25/15/50 set is refused with the exact sentence the AC quotes,
--        "Term weightage must total 100.00%, currently 90.00%", and NO term
--        changes status. Asserted through the RPC, and again through a raw
--        UPDATE as service_role so the trigger is what answers rather than
--        the function's own pre-check.
--   AC3  a frozen term refuses weightage edits from every path (RPC, raw
--        UPDATE as service_role) with the recompute-request message, and
--        both freeze sources are exercised: the term-level lock that FR-I16
--        will call, and academic_session.result_locked_at, which is real
--        today.
--   AC4  a non-counting term with a NON-ZERO weight is excluded from the
--        100% total and still shows up as selectable. Deliberately non-zero:
--        a 0% weekly test would pass the sum whether it were excluded or
--        merely added as zero, and would prove nothing.
--
-- Weightage is basis points end to end (1 bp = 0.01%, 100.00% = 10000), the
-- same smallest-unit discipline as paisa money in this schema. The
-- percentage-facing surface (upsert_exam_term, set_exam_term_weight,
-- weight_pct) is asserted against it in both directions.
begin;
select plan(54);

select public.provision_tenant('test-exam-term-co', 'Exam Term Co', 'owner@examterm.test');
select id as tenant_id from public.tenant where slug = 'test-exam-term-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@examterm.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Exam Term Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@examterm.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@examterm.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Nusrat Jamil');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'teacher@examterm.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'class_teacher', 'Ahmed Raza');

-- A second campus with its own session, so campus scope and the per-campus
-- weightage total both have something to be wrong about.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.create_campus('SOUTH', 'Campus South', null) as _c \gset
select id as campus_b from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset

select id as session_a from public.academic_session where tenant_id = :'tenant_id' and campus_id = :'campus_a' \gset
select public.create_academic_session(
  :'campus_b'::uuid, 'South 2026-27', date '2026-04-01', date '2027-03-31'
) as session_b \gset

reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: First Term 25%, Mid 15%, Pre-Board 0% (non-counting), Final 60%
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.upsert_exam_term(:'campus_a', :'session_a', 'T1',  'First Term', 1::smallint, 25.00) as term_t1 \gset
select public.upsert_exam_term(:'campus_a', :'session_a', 'MID', 'Mid Term',   2::smallint, 15.00) as term_mid \gset
select public.upsert_exam_term(:'campus_a', :'session_a', 'PB',  'Pre-Board',  3::smallint,  0.00, false) as term_pb \gset
select public.upsert_exam_term(:'campus_a', :'session_a', 'FIN', 'Final Term', 4::smallint, 60.00) as term_fin \gset

select is(
  (select count(*)::int from public.exam_term where session_id = :'session_a' and status = 'draft'),
  4,
  'AC1: an Exam Controller defines four terms, all of them draft until activated'
);
select is(
  (select count(*)::int from public.v_exam_term_selectable where session_id = :'session_a'),
  0,
  'AC1: and none of them is selectable in mark entry before activation'
);
select results_eq(
  format($$ select code, weight_pct, counts_toward_annual
              from public.exam_term where session_id = %L order by sequence $$, :'session_a'),
  $$ values ('T1',  25.00::numeric(5,2), true),
            ('MID', 15.00::numeric(5,2), true),
            ('PB',   0.00::numeric(5,2), false),
            ('FIN', 60.00::numeric(5,2), true) $$,
  'AC1: the set is the acceptance criteria''s — 25 / 15 / 0 non-counting / 60'
);

select is(
  public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid),
  4,
  'AC1: activation succeeds and moves all four terms out of draft'
);
select is(
  (select count(*)::int from public.exam_term where session_id = :'session_a' and status = 'active'),
  4,
  'AC1: every term is active'
);
select is(
  (select count(*)::int from public.v_exam_term_selectable where session_id = :'session_a'),
  4,
  'AC1: and all four are now selectable in mark entry, the 0% Pre-Board included'
);
select ok(
  (select weight_pct = 0.00 and not counts_toward_annual
     from public.exam_term where id = :'term_pb'),
  'AC1: Pre-Board is genuinely 0.00% and genuinely non-counting'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: counting terms weighted 25/15/50 — the exact refusal
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);

select public.upsert_exam_term(:'campus_b', :'session_b', 'T1',  'First Term', 1::smallint, 25.00) as b_t1 \gset
select public.upsert_exam_term(:'campus_b', :'session_b', 'MID', 'Mid Term',   2::smallint, 15.00) as b_mid \gset
select public.upsert_exam_term(:'campus_b', :'session_b', 'FIN', 'Final Term', 3::smallint, 50.00) as b_fin \gset

select throws_ok(
  format($$ select public.activate_exam_terms(%L, %L) $$, :'session_b', :'campus_b'),
  '22023',
  'Term weightage must total 100.00%, currently 90.00%',
  'AC2: activation is refused, with the message the acceptance criteria quote verbatim'
);
select is(
  (select count(*)::int from public.exam_term where session_id = :'session_b' and status = 'draft'),
  3,
  'AC2: and NO term changes status'
);
select is(
  (select count(*)::int from public.exam_term where session_id = :'session_b' and status <> 'draft'),
  0,
  'AC2: not one of them slipped through to active'
);
select throws_ok(
  format($$ select public.fn_validate_term_weightage(%L, %L) $$, :'session_b', :'campus_b'),
  '22023',
  'Term weightage must total 100.00%, currently 90.00%',
  'AC2: the validator raises the same sentence when called on its own'
);

-- The trigger, not the function's pre-check, is what makes this true: a raw
-- UPDATE as service_role (BYPASSRLS, every table grant) is refused too.
reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ update public.exam_term set status = 'active' where session_id = %L $$, :'session_b'),
  '22023',
  'Term weightage must total 100.00%, currently 90.00%',
  'AC2: a raw UPDATE as service_role is refused by trg_exam_term_weightage_check, not by the RPC'
);
reset role;
select is(
  (select count(*)::int from public.exam_term where session_id = :'session_b' and status = 'draft'),
  3,
  'AC2: the whole statement aborted — all three terms are still draft'
);

-- The "currently" figure is computed, not a constant: over 100 reads back
-- just as exactly, with the same two decimal places.
update public.exam_term set weight_bp = 6500 where id = :'b_fin';
select throws_ok(
  format($$ select public.fn_validate_term_weightage(%L, %L) $$, :'session_b', :'campus_b'),
  '22023',
  'Term weightage must total 100.00%, currently 105.00%',
  'AC2: an over-100 total is reported with the same formatting'
);
update public.exam_term set weight_bp = 4550 where id = :'b_fin';
select throws_ok(
  format($$ select public.fn_validate_term_weightage(%L, %L) $$, :'session_b', :'campus_b'),
  '22023',
  'Term weightage must total 100.00%, currently 85.50%',
  'AC2: and a fractional total keeps its basis points — 85.50%, not 85% or 86%'
);
update public.exam_term set weight_bp = 6000 where id = :'b_fin';

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: a non-counting term is excluded from the 100% validation
-- ═══════════════════════════════════════════════════════════════════════
-- Campus B is now 25 + 15 + 60 = 100 across its counting terms. A weekly
-- test carrying a NON-ZERO 10% is added as non-counting: if exclusion were
-- fake, the total would read 110.00% and activation would fail.

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select public.upsert_exam_term(
  :'campus_b', :'session_b', 'WK', 'Weekly Tests', 4::smallint, 10.00, false
) as b_weekly \gset

select lives_ok(
  format($$ select public.fn_validate_term_weightage(%L, %L) $$, :'session_b', :'campus_b'),
  'AC4: a 10% non-counting weekly-test term is EXCLUDED from the 100% total'
);
select is(
  public.activate_exam_terms(:'session_b'::uuid, :'campus_b'::uuid),
  4,
  'AC4: so the set activates, weekly tests and all'
);
select ok(
  (select true from public.v_exam_term_selectable where id = :'b_weekly'),
  'AC4: and the non-counting term still appears for the report card'
);

-- Flip it to counting and the same set is suddenly 110% — which is the
-- proof that the exclusion above was doing real work. The flip has to be
-- made as the table owner: exam_term has a SELECT policy and no UPDATE
-- policy, so a client's direct write matches no rows at all.
update public.exam_term set counts_toward_annual = true where id = :'b_weekly';
select is(
  (select counts_toward_annual from public.exam_term where id = :'b_weekly'),
  false,
  'writes go through the RPCs: a direct client UPDATE reaches no row, because RLS grants no UPDATE policy'
);
reset role;
update public.exam_term set counts_toward_annual = true where id = :'b_weekly';
select throws_ok(
  format($$ select public.fn_validate_term_weightage(%L, %L) $$, :'session_b', :'campus_b'),
  '22023',
  'Term weightage must total 100.00%, currently 110.00%',
  'AC4: counted, the very same 10% term takes the total to 110% — the exclusion was real'
);
update public.exam_term set counts_toward_annual = false where id = :'b_weekly';

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: a term with approved marks refuses weightage edits
-- ═══════════════════════════════════════════════════════════════════════
-- No marks exist in this schema (FR-I12/FR-I16 are later FRs). The freeze
-- predicate has two sources and both are exercised: lock_exam_term(), the
-- seam FR-I16 calls when it approves a mark set, and
-- academic_session.result_locked_at, which ships today.

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select lives_ok(
  format($$ select public.lock_exam_term(%L) $$, :'term_fin'),
  'FR-I16 seam: approving a mark set locks the term'
);
select is(
  (select status::text from public.exam_term where id = :'term_fin'),
  'locked',
  'the locked term keeps its own status rather than pretending to be draft'
);
select ok(
  app.fn_exam_term_weight_frozen(:'term_fin'::uuid),
  'AC3: the freeze predicate is true for it'
);
select ok(
  not app.fn_exam_term_weight_frozen(:'term_t1'::uuid),
  'AC3: and false for its unlocked sibling'
);

select throws_ok(
  format($$ select public.set_exam_term_weight(%L, 55.00) $$, :'term_fin'),
  '42501',
  'exam term weightage is locked by approved marks — raise a result-recompute request',
  'AC3: editing weight_pct is BLOCKED and the user is directed to a result-recompute request'
);
select throws_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'FIN', 'Final Term', 4::smallint, 55.00) $$,
         :'campus_a', :'session_a'),
  '42501',
  'exam term weightage is locked by approved marks — raise a result-recompute request',
  'AC3: and the upsert path is blocked identically — there is no second door'
);
select lives_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'FIN', 'Final Examination', 4::smallint, 60.00) $$,
         :'campus_a', :'session_a'),
  'AC3: renaming a frozen term is still allowed — only the aggregate''s inputs are shut'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ update public.exam_term set weight_bp = 5500 where id = %L $$, :'term_fin'),
  '42501',
  'exam term weightage is locked by approved marks — raise a result-recompute request',
  'AC3: a raw UPDATE as service_role is refused too — the trigger is the control'
);
select throws_ok(
  format($$ update public.exam_term set counts_toward_annual = false where id = %L $$, :'term_fin'),
  '42501',
  'exam term weightage is locked by approved marks — raise a result-recompute request',
  'AC3: and so is quietly dropping the term out of the annual aggregate'
);
reset role;
select is(
  (select weight_bp from public.exam_term where id = :'term_fin'),
  6000,
  'AC3: after every attempt the weightage is still 60.00%'
);

-- The second freeze source: a session whose results are locked freezes its
-- terms' weightage even when no individual term is locked.
select ok(
  not app.fn_exam_term_weight_frozen(:'b_t1'::uuid),
  'AC3: campus B''s First Term is not frozen while its session is open'
);
update public.academic_session set result_locked_at = now() where id = :'session_b';
select ok(
  app.fn_exam_term_weight_frozen(:'b_t1'::uuid),
  'AC3: locking the session''s results freezes its terms too'
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select throws_ok(
  format($$ select public.set_exam_term_weight(%L, 30.00) $$, :'b_t1'),
  '42501',
  'exam term weightage is locked by approved marks — raise a result-recompute request',
  'AC3: and the edit is blocked with the same direction to a recompute request'
);
reset role;
update public.academic_session set result_locked_at = null where id = :'session_b';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a', :'campus_b'), 'sub', :'owner_uid')::text,
  true
);
select lives_ok(
  format($$ select public.set_exam_term_weight(%L, 25.00) $$, :'b_t1'),
  'AC3: the freeze is a predicate over live state, not a one-way latch — reopening the session releases it'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Basis points: the representation, at its edges
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'X1', 'Thirds', 9::smallint, 33.333) $$,
         :'campus_b', :'session_b'),
  '22023',
  'WEIGHT_PRECISION',
  'a weight finer than one basis point is REFUSED, not silently rounded to 33.33'
);
select lives_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'X1', 'Thirds', 9::smallint, 33.33, false) $$,
         :'campus_b', :'session_b'),
  'two decimal places — exactly one basis point — is accepted'
);
select is(
  (select weight_bp from public.exam_term where session_id = :'session_b' and code = 'X1'),
  3333,
  'and 33.33% is stored as 3333 bp'
);
select is(
  (select weight_pct from public.exam_term where session_id = :'session_b' and code = 'X1'),
  33.33::numeric(5,2),
  'the generated weight_pct reads back the percentage the caller passed in'
);
select throws_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'X2', 'Too much', 10::smallint, 100.01) $$,
         :'campus_b', :'session_b'),
  '23514',
  'WEIGHT_OUT_OF_RANGE',
  'a single term cannot exceed 100%'
);
select throws_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'X3', 'Negative', 11::smallint, -1) $$,
         :'campus_b', :'session_b'),
  '23514',
  'WEIGHT_OUT_OF_RANGE',
  'nor be negative'
);
reset role;
select throws_ok(
  format($$ update public.exam_term set weight_pct = 50.00 where id = %L $$, :'b_t1'),
  '428C9',
  null,
  'weight_pct is generated: it cannot be written behind weight_bp''s back'
);
select throws_ok(
  format($$ insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence, weight_bp)
              values (%L, %L, %L, 'ZZ', 'Over the cap', 12, 10001) $$,
         :'tenant_id', :'campus_b', :'session_b'),
  '23514',
  null,
  'chk_exam_term_weight_bp is the backstop under the function''s own range check'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Roles, campus scope, RLS
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'class_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'CT', 'Sneaky', 20::smallint, 5.00) $$,
         :'campus_a', :'session_a'),
  '42501',
  'FORBIDDEN',
  'a Class Teacher cannot define exam terms'
);
select throws_ok(
  format($$ select public.activate_exam_terms(%L, %L) $$, :'session_a', :'campus_a'),
  '42501',
  'FORBIDDEN',
  'nor activate a term set'
);
select is(
  (select count(*)::int from public.exam_term where session_id = :'session_b'),
  0,
  'RLS: a campus-A user sees none of campus B''s terms'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select throws_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'EC', 'Out of scope', 21::smallint, 5.00) $$,
         :'campus_b', :'session_b'),
  '42501',
  'FORBIDDEN',
  'an Exam Controller posted to campus A cannot define terms for campus B'
);
select throws_ok(
  format($$ select public.activate_exam_terms(%L, %L) $$, :'session_b', :'campus_b'),
  '42501',
  'FORBIDDEN',
  'nor activate campus B''s set'
);

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select lives_ok(
  format($$ select public.upsert_exam_term(%L, %L, 'PR', 'Practice Test', 22::smallint, 0.00, false) $$,
         :'campus_a', :'session_a'),
  'a Principal can define exam terms as well as an Exam Controller'
);
select id as term_practice from public.exam_term where session_id = :'session_a' and code = 'PR' \gset
select lives_ok(
  format($$ select public.delete_exam_term(%L) $$, :'term_practice'),
  'a draft term can be removed outright'
);
select throws_ok(
  format($$ select public.delete_exam_term(%L) $$, :'term_t1'),
  '55000',
  'EXAM_TERM_NOT_DRAFT',
  'an activated term cannot be — removing it is a result correction, not a setup edit'
);
select throws_ok(
  format($$ select public.lock_exam_term(%L) $$, :'term_practice'),
  'P0002',
  'EXAM_TERM_NOT_FOUND',
  'and a term that no longer exists cannot be locked'
);

-- Uniqueness: the FR's index, and the campus dimension in it.
reset role;
select lives_ok(
  format($$ insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence, weight_bp)
              values (%L, %L, %L, 'DUP1', 'Sequence thirty', 30, 0) $$,
         :'tenant_id', :'campus_a', :'session_a'),
  'sequence 30 is free in campus A'
);
select throws_ok(
  format($$ insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence, weight_bp)
              values (%L, %L, %L, 'DUP2', 'Sequence thirty again', 30, 0) $$,
         :'tenant_id', :'campus_a', :'session_a'),
  '23505',
  null,
  'uq_exam_term_seq: two terms of one session+campus cannot share a sequence'
);
select lives_ok(
  format($$ insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence, weight_bp)
              values (%L, %L, %L, 'DUP3', 'Same sequence, other campus', 30, 0) $$,
         :'tenant_id', :'campus_b', :'session_b'),
  'but the same sequence in a different campus is fine — the index is campus-scoped'
);

select * from finish();
rollback;
