-- pgTAP tests for FR-I02: exam subject and component setup.
--
--   AC1  Class 9 Pre-Medical Biology, theory max 65 pass 23 + practical max
--        20 pass 7, totals 85 and yields TWO components for the grid to draw
--        columns from. Set up on the real FR-E05 stream and the real FR-E06
--        class_subject row, because "Pre-Medical Biology" is a stream-
--        specific curriculum entry and configuring it as if streams did not
--        exist would test nothing the AC asks about.
--   AC2  practical pass 7 of a maximum of 5 is refused with the acceptance
--        criteria's own sentence, "pass marks cannot exceed maximum marks" —
--        from the function, and from a raw INSERT as service_role, where
--        chk_pass_le_max is what answers.
--   AC3  Class 10 with THREE sections, configured once at class level: all
--        three resolve to the same configuration, with no per-section rows
--        anywhere.
--   AC4  Class 9 Computer Science with no configuration reports
--        ready=false and "exam setup pending — contact the exam office".
--
-- The freeze on editing a configuration once results ride on it reuses
-- FR-I01's app.fn_exam_term_weight_frozen(), so it is asserted here through
-- lock_exam_term() rather than re-tested from scratch.
begin;
select plan(48);

select public.provision_tenant('test-exam-subject-co', 'Exam Subject Co', 'owner@examsubject.test');
select id as tenant_id from public.tenant where slug = 'test-exam-subject-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@examsubject.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Exam Subject Owner');

select gen_random_uuid() as ec_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'ec_uid', 'controller@examsubject.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'ec_uid', :'tenant_id', 'exam_controller', 'Shaista Kamal');

select gen_random_uuid() as teacher_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_uid', 'teacher@examsubject.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_uid', :'tenant_id', 'subject_teacher', 'Ahmed Raza');

select id as class9  from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset
select id as class10 from public.class_level where tenant_id = :'tenant_id' and code = '10' \gset

-- ── the real FR-E04/E05/E06 objects this FR is built on ──────────────────

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_subject('BIO', 'Biology', 'حیاتیات')          as subj_bio \gset
select public.create_subject('CS',  'Computer Science', 'کمپیوٹر') as subj_cs  \gset
select public.create_subject('PT',  'Physical Training', 'ورزش', 'NON_EXAMINABLE'::public.subject_type, false) as subj_pt \gset
select public.create_stream('PRE_MED', 'Pre-Medical', 'پری میڈیکل', 'FBISE'::public.board, 10::smallint) as stream_med \gset

-- Class 9 Pre-Medical Biology: a STREAM-SPECIFIC curriculum row, which is
-- what AC1 is actually describing.
select public.upsert_class_subject(
  :'campus_a', :'session_a', :'class9', :'subj_bio', 6::smallint, :'stream_med'
) as cs_bio \gset
-- Class 9 Computer Science exists in the curriculum but will never be
-- configured for the exam — AC4's case.
select public.upsert_class_subject(
  :'campus_a', :'session_a', :'class9', :'subj_cs', 4::smallint
) as cs_cs \gset
-- Class 10 Biology, compulsory and stream-less, so every section takes it.
select public.upsert_class_subject(
  :'campus_a', :'session_a', :'class10', :'subj_bio', 5::smallint
) as cs10_bio \gset
select public.upsert_class_subject(
  :'campus_a', :'session_a', :'class9', :'subj_pt', 2::smallint
) as cs_pt \gset

-- AC3's three sections of Class 10, plus a Class 9 Pre-Medical section.
select public.create_section(:'campus_a', :'session_a', :'class10', 'A', 40) as sec10_a \gset
select public.create_section(:'campus_a', :'session_a', :'class10', 'B', 40) as sec10_b \gset
select public.create_section(:'campus_a', :'session_a', :'class10', 'C', 40) as sec10_c \gset
select public.create_section(:'campus_a', :'session_a', :'class9', 'PM', 35) as sec9_pm \gset
select public.set_section_stream(:'sec9_pm', :'stream_med') as _s \gset

-- FR-I01's term, activated so it is selectable.
select public.upsert_exam_term(:'campus_a', :'session_a', 'T1', 'First Term', 1::smallint, 100.00) as term_t1 \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: theory 65/23 + practical 20/7 = 85, two components
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);

select public.upsert_exam_subject(
  :'term_t1', :'cs_bio',
  '[{"component":"theory","max_marks":65,"pass_marks":23},
    {"component":"practical","max_marks":20,"pass_marks":7}]'::jsonb
) as es_bio \gset

select is(
  public.fn_exam_subject_total_max(:'es_bio'::uuid),
  85,
  'AC1: Class 9 Pre-Medical Biology totals 85 — theory 65 plus practical 20'
);
select is(
  (select count(*)::int from public.exam_subject_component where exam_subject_id = :'es_bio'),
  2,
  'AC1: and it has TWO components, one column each for the mark entry grid'
);
select results_eq(
  format($$ select component::text, max_marks, pass_marks, sequence
              from public.exam_subject_component where exam_subject_id = %L order by sequence $$, :'es_bio'),
  $$ values ('theory'::text,    65, 23, 1::smallint),
            ('practical'::text, 20,  7, 2::smallint) $$,
  'AC1: the components are stored as configured, in the order the grid should draw them'
);
select ok(
  (select stream_id = :'stream_med' from public.class_subject
    where id = (select class_subject_id from public.exam_subject where id = :'es_bio')),
  'AC1: and it hangs off the PRE-MEDICAL curriculum row, not a stream-less one'
);

-- The readiness function is what a grid would call, and it agrees.
select is(
  (public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') ->> 'ready')::boolean,
  true,
  'AC1: a teacher opening mark entry for the Pre-Medical section finds it ready'
);
select is(
  (public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') ->> 'total_max_marks')::int,
  85,
  'AC1: with a total max of 85'
);
select is(
  jsonb_array_length(public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') -> 'components'),
  2,
  'AC1: and TWO component columns to render'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') -> 'components' -> 0 ->> 'component',
  'theory',
  'AC1: theory first'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') -> 'components' -> 1 ->> 'component',
  'practical',
  'AC1: practical second'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') ->> 'message',
  null,
  'AC1: and nothing to apologise for'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: pass 7 of a maximum of 5
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":65,"pass_marks":23},
               {"component":"practical","max_marks":5,"pass_marks":7}]'::jsonb) $$,
         :'term_t1', :'cs_bio'),
  '23514',
  'pass marks cannot exceed maximum marks',
  'AC2: the save is refused, in the acceptance criteria''s own words'
);
select is(
  public.fn_exam_subject_total_max(:'es_bio'::uuid),
  85,
  'AC2: and the configuration that was already there is untouched — 85, not 70'
);
select is(
  (select max_marks from public.exam_subject_component
    where exam_subject_id = :'es_bio' and component = 'practical'),
  20,
  'AC2: the practical is still out of 20'
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":100,"pass_marks":101}]'::jsonb) $$,
         :'term_t1', :'cs10_bio'),
  '23514',
  'pass marks cannot exceed maximum marks',
  'AC2: one mark over the maximum is enough'
);
select lives_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":100,"pass_marks":100}]'::jsonb) $$,
         :'term_t1', :'cs10_bio'),
  'AC2: pass EQUAL to max is allowed — "cannot exceed", not "must be below"'
);

-- chk_pass_le_max is the backstop under the function's own check: a raw
-- INSERT as service_role, which has BYPASSRLS and every table grant, is
-- refused by the constraint.
reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
select throws_ok(
  format($$ insert into public.exam_subject_component
              (tenant_id, exam_subject_id, component, max_marks, pass_marks, sequence)
            values (%L, %L, 'viva', 5, 7, 9) $$,
         :'tenant_id', :'es_bio'),
  '23514',
  null,
  'AC2: chk_pass_le_max refuses it at the table too, whatever the caller'
);
reset role;

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: three sections of Class 10, configured once
-- ═══════════════════════════════════════════════════════════════════════

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'ec_uid')::text,
  true
);
select public.upsert_exam_subject(
  :'term_t1', :'cs10_bio',
  '[{"component":"theory","max_marks":75,"pass_marks":25},
    {"component":"internal","max_marks":25,"pass_marks":8}]'::jsonb
) as es10_bio \gset

select is(
  (select count(*)::int from public.exam_subject
    where exam_term_id = :'term_t1' and class_subject_id = :'cs10_bio'),
  1,
  'AC3: ONE configuration exists for Class 10 Biology, not one per section'
);
select is(
  (select count(distinct exam_subject_id)::int from public.v_exam_section_subject_setup
    where exam_term_id = :'term_t1' and subject_id = :'subj_bio'
      and section_id in (:'sec10_a', :'sec10_b', :'sec10_c')),
  1,
  'AC3: and all three sections resolve to that same one'
);
select is(
  (select count(*)::int from public.v_exam_section_subject_setup
    where exam_term_id = :'term_t1' and subject_id = :'subj_bio' and is_configured
      and section_id in (:'sec10_a', :'sec10_b', :'sec10_c')),
  3,
  'AC3: all three report themselves configured, with no further setup'
);
select results_eq(
  format($$ select section_name, total_max_marks, component_count
              from public.v_exam_section_subject_setup
             where exam_term_id = %L and subject_id = %L
               and section_id in (%L, %L, %L)
             order by section_name $$,
         :'term_t1', :'subj_bio', :'sec10_a', :'sec10_b', :'sec10_c'),
  $$ values ('A'::text, 100, 2), ('B'::text, 100, 2), ('C'::text, 100, 2) $$,
  'AC3: each section sees the same 100-mark, two-component setup'
);
select is(
  (public.fn_exam_entry_readiness(:'term_t1', :'sec10_b', :'subj_bio') ->> 'total_max_marks')::int,
  100,
  'AC3: a teacher of section B gets the class-level configuration'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec10_c', :'subj_bio') ->> 'class_subject_id',
  public.fn_exam_entry_readiness(:'term_t1', :'sec10_a', :'subj_bio') ->> 'class_subject_id',
  'AC3: and section C resolves to precisely the same curriculum row as section A'
);

-- The stream dimension still discriminates: Class 9's Pre-Medical Biology
-- is a different configuration from Class 10's stream-less one.
select isnt(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') ->> 'exam_subject_id',
  public.fn_exam_entry_readiness(:'term_t1', :'sec10_a', :'subj_bio') ->> 'exam_subject_id',
  'AC3: a stream-specific configuration is still its own — Class 9 Pre-Medical Biology is not Class 10 Biology'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: no configuration for Class 9 Computer Science
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_cs') ->> 'ready')::boolean,
  false,
  'AC4: Class 9 Computer Science is not ready for mark entry'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_cs') ->> 'message',
  'exam setup pending — contact the exam office',
  'AC4: with the message the acceptance criteria specify, word for word'
);
select is(
  jsonb_array_length(public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_cs') -> 'components'),
  0,
  'AC4: and no columns for a grid to draw'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_cs') ->> 'total_max_marks',
  null,
  'AC4: there is no denominator, and none is invented'
);
select ok(
  (public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_cs') ->> 'class_subject_id') is not null,
  'AC4: the subject IS in the curriculum — what is missing is the exam setup, and the answer says so'
);
select ok(
  not (select is_configured from public.v_exam_section_subject_setup
        where exam_term_id = :'term_t1' and section_id = :'sec9_pm' and subject_id = :'subj_cs'),
  'AC4: and the section view agrees it is unconfigured'
);

-- An exam_subject with no components at all is "pending" too: a grid with
-- zero columns is not a grid.
select lives_ok(
  format($$ select public.delete_exam_subject(%L) $$, :'es_bio'),
  'a configuration can be withdrawn while results are still open'
);
select is(
  public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') ->> 'message',
  'exam setup pending — contact the exam office',
  'AC4: withdrawing the configuration puts Biology back to pending'
);
select is(
  (select count(*)::int from public.exam_subject_component where exam_subject_id = :'es_bio'),
  0,
  'and its components went with it'
);
select public.upsert_exam_subject(
  :'term_t1', :'cs_bio',
  '[{"component":"theory","max_marks":65,"pass_marks":23},
    {"component":"practical","max_marks":20,"pass_marks":7}]'::jsonb
) as es_bio2 \gset

-- ═══════════════════════════════════════════════════════════════════════
-- Validation, reuse of module E, and the FR-I01 freeze
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L, '[]'::jsonb) $$, :'term_t1', :'cs_cs'),
  '23514',
  'COMPONENTS_REQUIRED',
  'a subject cannot be configured with no components at all'
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":50,"pass_marks":17},
               {"component":"theory","max_marks":30,"pass_marks":10}]'::jsonb) $$,
         :'term_t1', :'cs_cs'),
  '23514',
  'COMPONENT_DUPLICATED',
  'nor with two components of the same kind — the grid would have two identical columns'
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":0,"pass_marks":0}]'::jsonb) $$,
         :'term_t1', :'cs_cs'),
  '23514',
  'MARKS_OUT_OF_RANGE',
  'nor out of zero marks — that is not a denominator'
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb) $$,
         :'term_t1', :'cs_pt'),
  '23514',
  'SUBJECT_NOT_EXAMINABLE',
  'a NON_EXAMINABLE subject (FR-E04) cannot be given an exam configuration'
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb) $$,
         :'term_t1', :'owner_uid'),
  'P0002',
  'CLASS_SUBJECT_NOT_FOUND',
  'and a class-subject that does not exist is not silently created'
);

-- FR-I01's freeze, reused rather than reinvented.
select lives_ok(
  format($$ select public.lock_exam_term(%L) $$, :'term_t1'),
  'FR-I16 seam: marks are approved against the term'
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":80,"pass_marks":27}]'::jsonb) $$,
         :'term_t1', :'cs_bio'),
  '42501',
  'exam setup is locked by approved marks — raise a result-recompute request',
  'the denominator cannot be moved under marks that were already approved against it'
);
select throws_ok(
  format($$ select public.delete_exam_subject(%L) $$, :'es_bio2'),
  '42501',
  'exam setup is locked by approved marks — raise a result-recompute request',
  'and the configuration cannot be withdrawn either'
);
select is(
  public.fn_exam_subject_total_max(:'es_bio2'::uuid),
  85,
  'so Biology is still out of 85'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Roles, campus scope, RLS
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'teacher_uid')::text,
  true
);
select throws_ok(
  format($$ select public.upsert_exam_subject(%L, %L,
             '[{"component":"theory","max_marks":50,"pass_marks":17}]'::jsonb) $$,
         :'term_t1', :'cs_cs'),
  '42501',
  'TEACHER_NOT_ASSIGNED_TO_SUBJECT',
  'a Subject Teacher not assigned to the subject cannot configure its exam'
);
select is(
  (public.fn_exam_entry_readiness(:'term_t1', :'sec9_pm', :'subj_bio') ->> 'ready')::boolean,
  true,
  'but they CAN ask whether mark entry is ready, which is the whole point of AC4'
);
select is(
  (select count(*)::int from public.exam_subject_component where exam_subject_id = :'es_bio2'),
  2,
  'and read the components their grid needs'
);

-- A different tenant sees none of it.
reset role;
select public.provision_tenant('other-exam-subject-co', 'Other Co', 'owner@other.test');
select id as other_tenant from public.tenant where slug = 'other-exam-subject-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'owner_uid')::text,
  true
);
select is(
  (select count(*)::int from public.exam_subject),
  0,
  'RLS: another tenant sees no exam subjects'
);
select is(
  (select count(*)::int from public.exam_subject_component),
  0,
  'RLS: nor any components'
);
select is(
  (select count(*)::int from public.v_exam_section_subject_setup),
  0,
  'RLS: nor anything through the section view'
);
select throws_ok(
  format($$ select public.fn_exam_entry_readiness(%L, %L, %L) $$, :'term_t1', :'sec9_pm', :'subj_bio'),
  '42501',
  'FORBIDDEN',
  'RLS: and cannot ask about another tenant''s section, even holding its id'
);

select * from finish();
rollback;
