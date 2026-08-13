-- pgTAP tests for FR-I17: break-glass mark unlock.
--
--   AC1  the Exam Controller requests an unlock with a written reason; the
--        marks stay locked until a Principal approves, and an attempt to
--        self-approve is refused.
--   AC2  approved with a 60-minute window: the deadline is exactly that, a
--        live window survives the sweep, and once the clock passes it the
--        scheduled job re-locks the set and further edits fail.
--   AC3  an edit inside the window writes a mark_entry_audit row with old
--        value, new value, actor and unlock request id, and the section's
--        result is marked stale.
--   AC4  three unlocks on one exam_subject in one term put that subject in the
--        Owner's exceptions report with its reasons and approvers.
--
-- Plus the append-only guards on all three tables (authenticated, service_role,
-- the table owner and TRUNCATE, per the FR-T02/T08/I16 precedent), the
-- born-pending guard that stops an INSERT walking around the approval, the
-- security_event alert, and tenant isolation.
begin;
select plan(66);

select public.provision_tenant('test-break-glass-co', 'Break Glass Co', 'owner@breakglass.test');
select id as tenant_id from public.tenant where slug = 'test-break-glass-co' \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_a from public.academic_session where tenant_id = :'tenant_id' \gset

select gen_random_uuid() as owner_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_uid', 'owner@breakglass.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_uid', :'tenant_id', 'owner', 'Break Glass Owner');

select gen_random_uuid() as controller_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'controller_uid', 'controller@breakglass.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'controller_uid', :'tenant_id', 'exam_controller', 'Rukhsana Bano');

select gen_random_uuid() as principal_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'principal_uid', 'principal@breakglass.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'principal_uid', :'tenant_id', 'principal', 'Farhan Qureshi');

select id as class9 from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);

select public.create_subject('MTH', 'Maths', 'ریاضی') as subj_mth \gset
select public.upsert_class_subject(:'campus_a', :'session_a', :'class9', :'subj_mth', 6::smallint) as cs_mth \gset
-- AC1's Class 9-B Maths.
select public.create_section(:'campus_a', :'session_a', :'class9', 'B', 40) as sec9b \gset

select public.upsert_exam_term(:'campus_a', :'session_a', 'T1', 'First Term', 1::smallint, 100.00) as term_t1 \gset
select public.activate_exam_terms(:'session_a'::uuid, :'campus_a'::uuid) as _a \gset
select public.upsert_exam_subject(
  :'term_t1', :'cs_mth', '[{"component":"theory","max_marks":100,"pass_marks":33}]'::jsonb
) as es_mth \gset

reset role;
insert into public.student (tenant_id, campus_id, gr_number, name_en, dob, gender)
select :'tenant_id', :'campus_a', 'GR-' || lpad(g::text, 4, '0'),
       'Candidate ' || lpad(g::text, 2, '0'), current_date - interval '14 years', 'male'
  from generate_series(1, 6) g;
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, roll_no)
select :'tenant_id', :'campus_a', :'session_a', st.id, :'class9', :'sec9b', right(st.gr_number, 4)::int
  from public.student st where st.tenant_id = :'tenant_id';

select id as enr1 from public.enrolment where section_id = :'sec9b' and roll_no = 1 \gset

-- The controller marks and signs off the paper: there has to be a lock before
-- there is anything to break the glass on.
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select count(*)::int as seeded
  from public.enrolment e,
       lateral (
         select public.fn_upsert_marks(jsonb_build_object(
           'exam_subject_id', :'es_mth',
           'marks', jsonb_build_array(jsonb_build_object(
             'enrolment_id', e.id, 'component', 'theory', 'marks_obtained', 40 + e.roll_no))))
       ) s
 where e.section_id = :'sec9b' \gset
select (public.fn_approve_marks(:'es_mth', :'sec9b') ->> 'marks_locked')::int as _locked \gset

-- ═══════════════════════════════════════════════════════════════════════
-- AC1: the request, and the approval that is never the requester's
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ select public.request_mark_unlock(%L, %L, 'oops') $$, :'es_mth', :'sec9b'),
  '23514',
  'UNLOCK_REASON_REQUIRED',
  'AC1: a break-glass request without a written reason is not a request'
);

select public.request_mark_unlock(:'es_mth', :'sec9b', 'Q5 total mis-added on 6 scripts') as req1 \gset

select is(
  (select status::text from public.mark_unlock_request where id = :'req1'),
  'pending',
  'AC1: the request is raised, and it is pending'
);
select is(
  (select reason from public.mark_unlock_request where id = :'req1'),
  'Q5 total mis-added on 6 scripts',
  'AC1: carrying the reason verbatim'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 99)))) $$,
         :'es_mth', :'enr1'),
  '42501',
  'marks_locked',
  'AC1: and the marks stay locked while it waits — asking is not being granted'
);
select is(
  (select unlock_state::text from public.mark_lock
    where exam_subject_id = :'es_mth' and section_id = :'sec9b'),
  'locked',
  'AC1: the lock row has not moved either'
);

-- The Exam Controller who raised it cannot grant it, in either of the two
-- independent ways it is refused.
select throws_ok(
  format($$ select public.fn_break_glass_unlock(%L) $$, :'req1'),
  '42501',
  'UNLOCK_APPROVER_ONLY',
  'AC1: an Exam Controller cannot grant a break-glass unlock at all'
);
select throws_ok(
  format($$ select public.request_mark_unlock(%L, %L, 'a second live justification') $$, :'es_mth', :'sec9b'),
  '23505',
  'UNLOCK_ALREADY_OPEN',
  'a set cannot carry two live justifications at once'
);

-- An Owner who raised a request cannot approve it either — the rule is about
-- the person, not the role.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select throws_ok(
  format($$ select public.fn_break_glass_unlock(%L) $$, :'req1'),
  '42501',
  'UNLOCK_SELF_APPROVAL',
  'AC1: an attempt to self-approve is refused even holding a role that may approve'
);

-- The Principal.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select throws_ok(
  format($$ select public.fn_break_glass_unlock(%L, 999) $$, :'req1'),
  '23514',
  'UNLOCK_WINDOW_OUT_OF_RANGE',
  'AC2: and the window they grant is bounded — no all-day unlock'
);

select public.fn_break_glass_unlock(:'req1') as _grant \gset

select is(
  (select status::text from public.mark_unlock_request where id = :'req1'),
  'approved',
  'AC1: the Principal grants it'
);
select is(
  (select approved_by from public.mark_unlock_request where id = :'req1'),
  :'principal_uid'::uuid,
  'AC1: recorded against them, not against the requester'
);
select is(
  (select unlock_state::text from public.mark_lock
    where exam_subject_id = :'es_mth' and section_id = :'sec9b'),
  'unlocked',
  'AC1: and only now does the lock row move'
);

-- The alert. See the migration header for why this is beside audit_log rather
-- than instead of it.
select is(
  (select count(*)::int from public.security_event
    where event_type = 'mark_break_glass_unlock' and subject_id = :'req1' and severity = 'alert'),
  1,
  'a break-glass grant raises a security_event alert the Principal actually reads'
);
select is(
  (select detail ->> 'reason' from public.security_event where subject_id = :'req1'),
  'Q5 total mis-added on 6 scripts',
  'carrying the reason, so the alert says why without a join'
);
select ok(
  (select count(*) from public.audit_log
    where table_name = 'mark_unlock_request' and row_id = :'req1'::uuid) >= 2,
  'and audit_log holds the hash-chained record of the request AND the decision'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the deadline
-- ═══════════════════════════════════════════════════════════════════════

select is(
  (select expires_at - approved_at from public.mark_unlock_request where id = :'req1'),
  interval '60 minutes',
  'AC2: approved at 14:00 with a 60-minute window expires at 15:00, exactly'
);
select is(
  public.fn_relock_expired_unlocks(),
  0,
  'AC2: the five-minute sweep leaves a live window alone'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC3: an edit inside the window
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);

select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr1' and component_code = 'theory'),
  41.00::numeric,
  'the mark as signed off'
);
select lives_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 47)))) $$,
         :'es_mth', :'enr1'),
  'AC3: inside the window the correction lands'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr1' and component_code = 'theory'),
  47.00::numeric,
  'AC3: and the corrected value is stored'
);

select is(
  (select count(*)::int from public.mark_entry_audit where mark_unlock_request_id = :'req1'),
  1,
  'AC3: one audit row, keyed to the unlock request that authorised it'
);
select is(
  (select old_marks from public.mark_entry_audit where mark_unlock_request_id = :'req1'),
  41.00::numeric,
  'AC3: capturing the OLD value'
);
select is(
  (select new_marks from public.mark_entry_audit where mark_unlock_request_id = :'req1'),
  47.00::numeric,
  'AC3: and the new one'
);
select is(
  (select actor_user_id from public.mark_entry_audit where mark_unlock_request_id = :'req1'),
  :'controller_uid'::uuid,
  'AC3: and who made it'
);

-- "every affected report card is marked stale"
select ok(
  (select result_stale_at is not null from public.mark_lock
    where exam_subject_id = :'es_mth' and section_id = :'sec9b'),
  'AC3: the signed-off set is stamped stale'
);
select is(
  (select result_stale_request_id from public.mark_lock
    where exam_subject_id = :'es_mth' and section_id = :'sec9b'),
  :'req1'::uuid,
  'AC3: naming the window that made it so'
);
select is(
  (public.fn_term_result_ready(:'term_t1', :'sec9b') ->> 'stale')::boolean,
  true,
  'AC3: and the result gate FR-J02 asks reports it — a computed result is now out of date'
);
select is(
  public.fn_term_result_ready(:'term_t1', :'sec9b') -> 'stale_subjects' ->> 0,
  'Maths',
  'AC3: naming the subject that changed'
);
select is(
  (public.fn_term_result_ready(:'term_t1', :'sec9b') ->> 'ready')::boolean,
  true,
  'AC3: stale is not "cannot compute" — the marks are still all signed off'
);

-- A second cell in the same window adds a second trail row and does NOT
-- re-stamp the lock: result_stale_at is when this window first touched the set.
select id as enr2 from public.enrolment where section_id = :'sec9b' and roll_no = 2 \gset
select public.fn_upsert_marks(jsonb_build_object(
  'exam_subject_id', :'es_mth',
  'marks', jsonb_build_array(jsonb_build_object(
    'enrolment_id', :'enr2', 'component', 'theory', 'marks_obtained', 51)))) as _e2 \gset
select is(
  (select count(*)::int from public.mark_entry_audit where mark_unlock_request_id = :'req1'),
  2,
  'AC3: every cell touched inside the window leaves its own row'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC2: the clock passes 15:00
-- ═══════════════════════════════════════════════════════════════════════

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select is(
  public.fn_relock_expired_unlocks(clock_timestamp() + interval '61 minutes'),
  1,
  'AC2: the scheduled job re-locks the set once the clock is past the deadline'
);
select is(
  (select status::text from public.mark_unlock_request where id = :'req1'),
  'expired',
  'AC2: the request is closed'
);
select ok(
  (select relocked_at is not null from public.mark_unlock_request where id = :'req1'),
  'AC2: with the moment it was closed on the record'
);
select is(
  (select unlock_state::text from public.mark_lock
    where exam_subject_id = :'es_mth' and section_id = :'sec9b'),
  'locked',
  'AC2: and the lock row is back to locked'
);
select throws_ok(
  format($$ select public.fn_upsert_marks(jsonb_build_object(
              'exam_subject_id', %L,
              'marks', jsonb_build_array(jsonb_build_object(
                'enrolment_id', %L, 'component', 'theory', 'marks_obtained', 12)))) $$,
         :'es_mth', :'enr1'),
  '42501',
  'marks_locked',
  'AC2: further edits fail, with the browser tab still open'
);
select is(
  (select marks_obtained from public.mark_entry
    where exam_subject_id = :'es_mth' and enrolment_id = :'enr1' and component_code = 'theory'),
  47.00::numeric,
  'AC2: the correction made inside the window stands'
);

-- ═══════════════════════════════════════════════════════════════════════
-- AC4: three unlocks on one paper
-- ═══════════════════════════════════════════════════════════════════════

-- Two more windows, each raised, granted and closed the same way.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select public.request_mark_unlock(:'es_mth', :'sec9b', 'Practical sheet swapped between two candidates') as req2 \gset
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'req2', 30) as _g2 \gset
select public.fn_relock_expired_unlocks(clock_timestamp() + interval '31 minutes') as _s2 \gset

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select public.request_mark_unlock(:'es_mth', :'sec9b', 'Board erratum on question 11 applied late') as req3 \gset
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'owner_uid')::text,
  true
);
select public.fn_break_glass_unlock(:'req3', 15) as _g3 \gset
select public.fn_relock_expired_unlocks(clock_timestamp() + interval '16 minutes') as _s3 \gset

select is(
  (select unlock_count from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  3,
  'AC4: three unlocks on the same exam_subject put it in the Owner''s exceptions report'
);
select is(
  (select subject_name from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  'Maths',
  'AC4: named as the paper it is'
);
select is(
  (select array_length(reasons, 1) from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  3,
  'AC4: with its reasons'
);
select ok(
  (select 'Q5 total mis-added on 6 scripts' = any(reasons)
     from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  'AC4: the first of them verbatim'
);
select ok(
  (select 'Farhan Qureshi' = any(approvers) and 'Break Glass Owner' = any(approvers)
     from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  'AC4: and its approvers, both of them'
);
select is(
  (select windows_with_edits from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  1,
  'AC4: and how many of the three actually changed a mark, which is the sharper question'
);

-- A rejected request is not an unlock and does not enter the report.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'exam_controller',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select public.request_mark_unlock(:'es_mth', :'sec9b', 'Teacher asked to see the scripts again') as req4 \gset
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'principal_uid')::text,
  true
);
select public.reject_mark_unlock(:'req4', 'Marks are correct — scripts already re-checked') as _r4 \gset
select is(
  (select unlock_count from public.v_mark_unlock_exception where exam_subject_id = :'es_mth'),
  3,
  'AC4: a REFUSED request is not an unlock and never appears in the report'
);
select is(
  (select unlock_state::text from public.mark_lock
    where exam_subject_id = :'es_mth' and section_id = :'sec9b'),
  'locked',
  'and refusing one opens nothing'
);

-- ═══════════════════════════════════════════════════════════════════════
-- The append-only guards
-- ═══════════════════════════════════════════════════════════════════════

select throws_ok(
  format($$ update public.mark_unlock_request set reason = 'something else' where id = %L $$, :'req1'),
  '42501',
  'break-glass request is append-only',
  'an authenticated Principal cannot rewrite the reason they approved'
);
select lives_ok(
  format($$ delete from public.mark_unlock_request where id = %L $$, :'req1'),
  'their DELETE qualifies no rows at all'
);
select is(
  (select count(*)::int from public.mark_unlock_request where id = :'req1'),
  1,
  'so the request is still there'
);

reset role;
select set_config('request.jwt.claims', '', true);
set local role service_role;
-- The hole an INSERT would be: a pre-approved request walks past the approval.
select throws_ok(
  format($$ insert into public.mark_unlock_request
              (tenant_id, campus_id, exam_term_id, exam_subject_id, section_id, requested_by,
               reason, approved_by, approved_at, expires_at, status)
            values (%L, %L, %L, %L, %L, %L, 'forged by a service role key', %L, now(), now() + interval '1 hour', 'approved') $$,
         :'tenant_id', :'campus_a', :'term_t1', :'es_mth', :'sec9b', :'controller_uid', :'principal_uid'),
  '42501',
  'a break-glass request is born pending',
  'a service_role key cannot INSERT a pre-approved window and walk past the lock'
);
select throws_ok(
  format($$ update public.mark_unlock_request set expires_at = now() + interval '1 day' where id = %L $$, :'req1'),
  '42501',
  'break-glass request is append-only',
  'nor extend one that has closed'
);
select throws_ok(
  format($$ delete from public.mark_unlock_request where id = %L $$, :'req1'),
  '42501',
  'break-glass request is append-only',
  'nor delete the record that it happened'
);
select throws_ok(
  format($$ update public.mark_entry_audit set new_marks = 41 where mark_unlock_request_id = %L $$, :'req1'),
  '42501',
  'break-glass mark trail is append-only',
  'nor rewrite what the window changed'
);
select throws_ok(
  format($$ delete from public.mark_entry_audit where mark_unlock_request_id = %L $$, :'req1'),
  '42501',
  'break-glass mark trail is append-only',
  'nor erase it'
);
select throws_ok(
  format($$ update public.mark_lock set unlock_state = 'unlocked' where exam_subject_id = %L $$, :'es_mth'),
  '42501',
  'mark approval is append-only',
  'and unlock_state still moves only inside FR-I17''s named transitions'
);
reset role;

-- The table owner, writing the statements by hand.
select throws_ok(
  format($$ update public.mark_unlock_request set status = 'approved' where id = %L $$, :'req1'),
  '42501',
  'break-glass request is append-only',
  'the table owner is held to all of it too'
);
select throws_ok(
  format($$ delete from public.mark_entry_audit where mark_unlock_request_id = %L $$, :'req1'),
  '42501',
  'break-glass mark trail is append-only',
  'in both tables'
);
select throws_ok(
  format($$ update public.mark_lock set unlock_state = 'unlocked' where exam_subject_id = %L $$, :'es_mth'),
  '42501',
  'mark approval is append-only',
  'and on the lock the whole thing hangs off'
);
-- TRUNCATE fires no row trigger and consults no RLS.
select throws_ok(
  $$ truncate table public.mark_unlock_request cascade $$,
  '42501',
  'break-glass request is append-only',
  'TRUNCATE, which no row trigger and no policy would have caught'
);
select throws_ok(
  $$ truncate table public.mark_entry_audit cascade $$,
  '42501',
  'break-glass mark trail is append-only',
  'and the same on the trail'
);

-- ═══════════════════════════════════════════════════════════════════════
-- Tenant isolation
-- ═══════════════════════════════════════════════════════════════════════

select public.provision_tenant('other-break-glass-co', 'Other Co', 'owner@otherbreakglass.test');
select id as other_tenant from public.tenant where slug = 'other-break-glass-co' \gset
select id as other_campus from public.campus where tenant_id = :'other_tenant' \gset
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant', 'app_role', 'owner',
                    'campus_ids', json_build_array(:'other_campus'), 'sub', :'owner_uid')::text,
  true
);
select is((select count(*)::int from public.mark_unlock_request), 0, 'RLS: another tenant sees no unlock requests');
select is((select count(*)::int from public.mark_entry_audit), 0, 'RLS: nor the trail of what they changed');
select is((select count(*)::int from public.v_mark_unlock_exception), 0, 'RLS: nor the exceptions report');
select throws_ok(
  format($$ select public.request_mark_unlock(%L, %L, 'reaching into another school') $$, :'es_mth', :'sec9b'),
  '23514',
  'MARKS_NOT_LOCKED',
  'RLS: and cannot raise a request against another tenant''s paper, even holding its id'
);
select throws_ok(
  format($$ select public.fn_break_glass_unlock(%L) $$, :'req4'),
  'P0002',
  'UNLOCK_REQUEST_NOT_FOUND',
  'RLS: nor grant one'
);
select is(
  public.fn_relock_expired_unlocks(clock_timestamp() + interval '1 year'),
  0,
  'RLS: and their sweep never touches another tenant''s windows'
);

-- A Subject Teacher is not in any of this.
reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher',
                    'campus_ids', json_build_array(:'campus_a'), 'sub', :'controller_uid')::text,
  true
);
select throws_ok(
  format($$ select public.request_mark_unlock(%L, %L, 'I would like to fix a mark') $$, :'es_mth', :'sec9b'),
  '42501',
  'FORBIDDEN',
  'a teacher cannot even raise a break-glass request'
);
select is((select count(*)::int from public.mark_unlock_request), 0, 'RLS: nor read one');

select * from finish();
rollback;
