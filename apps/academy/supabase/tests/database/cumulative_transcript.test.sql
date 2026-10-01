-- pgTAP tests for FR-J13: cumulative academic transcript.
--
--   AC1  a student enrolled 2019-2026 across two campuses of one tenant: all 7
--        sessions, chronological, the campus named against each.
--   AC2  a session the student left in March: completed terms listed, annotated
--        "incomplete — left March 2023".
--   AC3  a current session with a withheld result: prior sessions still print,
--        the current one is marked "withheld".
--   AC4  an issued transcript carries serial number, issuing officer and issue
--        date, and a matching issuance record exists.
--
-- Plus: it still renders after a campus is closed, serials are unique and never
-- reused, the register is append-only, and access is limited by tenant, role
-- and campus.
begin;
select plan(35);

select public.provision_tenant('test-trans-co', 'Transcript Co', 'owner@transco.test');
select id as tenant_id from public.tenant where slug = 'test-trans-co' \gset
select id as campus_b from public.campus where tenant_id = :'tenant_id' \gset
select public.provision_tenant('test-trans-rival', 'Transcript Rival', 'owner@transrival.test');
select id as rival_id from public.tenant where slug = 'test-trans-rival' \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Old Town Campus', 'OLD') returning id as campus_a \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Third Campus', 'THR') returning id as campus_c \gset

select gen_random_uuid() as owner_uid \gset
select gen_random_uuid() as prin_b_uid \gset
select gen_random_uuid() as prin_c_uid \gset
select gen_random_uuid() as clerk_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role) values
  (:'owner_uid', 'o@transco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'prin_b_uid', 'pb@transco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'prin_c_uid', 'pc@transco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'clerk_uid', 'c@transco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'parent_uid', 'p@transco.test', 'x', now(), 'authenticated', 'authenticated'),
  (:'rival_uid', 'r@transrival.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'owner_uid', :'tenant_id', 'owner', 'Owner'), (:'prin_b_uid', :'tenant_id', 'principal', 'Tahira Aziz'),
  (:'prin_c_uid', :'tenant_id', 'principal', 'Third Principal'), (:'clerk_uid', :'tenant_id', 'accountant', 'Clerk'),
  (:'rival_uid', :'rival_id', 'owner', 'Rival Owner');
insert into public.user_campus (user_id, tenant_id, campus_id) values
  (:'prin_b_uid', :'tenant_id', :'campus_b'), (:'prin_c_uid', :'tenant_id', :'campus_c'), (:'clerk_uid', :'tenant_id', :'campus_b');

-- The student, created the ordinary way in Campus B.
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_b', :'campus_a'), 'sub', :'owner_uid')::text, true);
select public.create_student(:'campus_b', 'Zainab Hussain', '2008-02-02'::date, 'female', 'Hussain Ali') as st \gset
select public.fn_find_or_create_guardian(p_name_en => 'Zainab Mother', p_phone_e164 => '+923005550061') as g \gset
select public.link_guardian(:'st'::uuid, :'g'::uuid, 'mother'::public.guardian_relationship, true, true);
reset role;
update public.guardian set auth_user_id = :'parent_uid'::uuid where id = :'g'::uuid;

-- ── Seven sessions, 2019-20 .. 2025-26, four at Old Town then three at Campus B ──
create temp table _s (n int, sid uuid, cid uuid, secid uuid, enr uuid);
update public.academic_session set is_current = false where tenant_id = :'tenant_id';
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
select :'tenant_id', case when n < 4 then :'campus_a'::uuid else :'campus_b'::uuid end,
       format('%s-%s', 2019 + n, right((2020 + n)::text, 2)), make_date(2019 + n, 4, 1), make_date(2020 + n, 3, 31),
       n = 6, case when n = 6 then 'active' else 'closed' end::public.session_status
  from generate_series(0, 6) n;
insert into _s (n, sid)
select (regexp_replace(name, '^(\d{4}).*', '\1')::int - 2019), id from public.academic_session
 where tenant_id = :'tenant_id' and name ~ '^20(19|2[0-5])-' and campus_id in (:'campus_a', :'campus_b');
update _s set cid = case when n < 4 then :'campus_a'::uuid else :'campus_b'::uuid end;

insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
select :'tenant_id', _s.cid, _s.sid, cl.id, 'A', 40 from _s join public.class_level cl on cl.tenant_id = :'tenant_id' and cl.code = (3 + _s.n)::text;
update _s set secid = (select id from public.class_section cs where cs.session_id = _s.sid);

-- Session 3 (2022-23) was left in March 2023; session 6 is the current one.
insert into public.enrolment (tenant_id, campus_id, session_id, student_id, class_level_id, section_id, status, joined_on, left_on)
select :'tenant_id', _s.cid, _s.sid, :'st', cs.class_level_id, _s.secid,
       (case when _s.n = 3 then 'left' else 'active' end)::public.enrolment_status, make_date(2019 + _s.n, 4, 1),
       case when _s.n = 3 then date '2023-03-15' end
  from _s join public.class_section cs on cs.id = _s.secid;
update _s set enr = (select id from public.enrolment e where e.session_id = _s.sid and e.student_id = :'st');

-- Subjects and annual results for sessions 0..2 (final), partial terms for 3.
insert into public.subject (tenant_id, code, name_en, name_ur) values (:'tenant_id', 'MTH', 'Maths', 'ریاضی'), (:'tenant_id', 'ENG', 'English', 'انگریزی');
insert into public.annual_result (tenant_id, campus_id, session_id, class_level_id, section_id, enrolment_id, subject_id, weighted_pct, grade_label, is_pass, status, terms_counted, terms_total, prorated_terms, is_blocked)
select :'tenant_id', _s.cid, _s.sid, cs.class_level_id, _s.secid, _s.enr, sub.id, 60 + _s.n, 'B', true, 'final', 1, 1, 0, false
  from _s join public.class_section cs on cs.id = _s.secid cross join public.subject sub
 where _s.n <= 2 and sub.tenant_id = :'tenant_id';

-- 2022-23: two terms were completed before leaving in March.
insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence, weight_bp, counts_toward_annual, status)
select :'tenant_id', _s.cid, _s.sid, t.code, t.name, t.seq, 5000, true, 'active' from _s cross join (values ('T1', 'First Term', 1), ('T2', 'Mid Term', 2)) t(code, name, seq) where _s.n = 3;
insert into public.class_subject (tenant_id, campus_id, session_id, class_level_id, subject_id, weekly_periods)
select :'tenant_id', _s.cid, _s.sid, cs.class_level_id, sub.id, 5 from _s join public.class_section cs on cs.id = _s.secid join public.subject sub on sub.tenant_id = :'tenant_id' and sub.code = 'MTH' where _s.n = 3;
insert into public.exam_subject (tenant_id, campus_id, exam_term_id, class_subject_id)
select :'tenant_id', _s.cid, t.id, c.id from _s join public.exam_term t on t.session_id = _s.sid join public.class_subject c on c.session_id = _s.sid where _s.n = 3;
insert into public.subject_result (tenant_id, campus_id, exam_term_id, section_id, exam_subject_id, enrolment_id, subject_id, obtained, max_marks, pct, is_pass)
select :'tenant_id', _s.cid, es.exam_term_id, _s.secid, es.id, _s.enr, c.subject_id, 70, 100, 70, true
  from _s join public.exam_subject es on es.campus_id = _s.cid join public.exam_term t on t.id = es.exam_term_id and t.session_id = _s.sid
  join public.class_subject c on c.id = es.class_subject_id where _s.n = 3;

-- 2025-26 (current): a term exists and the result is withheld.
insert into public.exam_term (tenant_id, campus_id, session_id, code, name, sequence, weight_bp, counts_toward_annual, status)
select :'tenant_id', _s.cid, _s.sid, 'T1', 'First Term', 1, 10000, true, 'active' from _s where _s.n = 6;
insert into public.result_withhold (tenant_id, campus_id, exam_term_id, enrolment_id, reason, cutoff_date)
select :'tenant_id', _s.cid, t.id, _s.enr, 'discipline', current_date from _s join public.exam_term t on t.session_id = _s.sid where _s.n = 6;
insert into public.annual_result (tenant_id, campus_id, session_id, class_level_id, section_id, enrolment_id, subject_id, weighted_pct, grade_label, is_pass, status, terms_counted, terms_total, prorated_terms, is_blocked)
select :'tenant_id', _s.cid, _s.sid, cs.class_level_id, _s.secid, _s.enr, sub.id, 88, 'A1', true, 'final', 1, 1, 0, false
  from _s join public.class_section cs on cs.id = _s.secid join public.subject sub on sub.tenant_id = :'tenant_id' and sub.code = 'MTH' where _s.n = 6;

-- A promotion decision on a finished year, to see it carried onto the document.
insert into public.promotion_decision (tenant_id, campus_id, session_id, class_level_id, enrolment_id, student_id, decision, system_decision)
select :'tenant_id', _s.cid, _s.sid, cs.class_level_id, _s.enr, :'st', 'promoted', 'promoted' from _s join public.class_section cs on cs.id = _s.secid where _s.n = 0;

-- ── AC1: the principal of the CURRENT campus gets the whole history ───────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'prin_b_uid')::text, true);
select public.fn_student_transcript(:'st'::uuid) as tr \gset

select is(jsonb_array_length(:'tr'::jsonb -> 'sessions'), 7, 'AC1: all seven sessions appear');
select is((select array_agg(s ->> 'session_name' order by ord) from jsonb_array_elements(:'tr'::jsonb -> 'sessions') with ordinality x(s, ord)),
          array['2019-20', '2020-21', '2021-22', '2022-23', '2023-24', '2024-25', '2025-26'], 'AC1: in chronological order');
select is((select array_agg(s ->> 'campus_name' order by ord) from jsonb_array_elements(:'tr'::jsonb -> 'sessions') with ordinality x(s, ord)),
          array['Old Town Campus', 'Old Town Campus', 'Old Town Campus', 'Old Town Campus', (select name from public.campus where id = :'campus_b'), (select name from public.campus where id = :'campus_b'), (select name from public.campus where id = :'campus_b')],
          'AC1: with the campus named against each, across two campuses');
select is(:'tr'::jsonb -> 'sessions' -> 0 ->> 'class_name', (select name_en from public.class_level where tenant_id = :'tenant_id' and code = '3'), 'each session names its class');
select is(:'tr'::jsonb -> 'sessions' -> 0 ->> 'status', 'complete', 'a finished year is complete');
select is(jsonb_array_length(:'tr'::jsonb -> 'sessions' -> 0 -> 'subjects'), 2, 'with its subject results');
select is(:'tr'::jsonb -> 'sessions' -> 0 ->> 'promotion_decision', 'promoted', 'and the promotion decision where there is one');
select is(:'tr'::jsonb -> 'student' ->> 'name_en', 'Zainab Hussain', 'the document identifies the student');

-- ── AC2 ───────────────────────────────────────────────────────────────────
select is(:'tr'::jsonb -> 'sessions' -> 3 ->> 'status', 'incomplete', 'AC2: the session she left in March is incomplete');
select is(:'tr'::jsonb -> 'sessions' -> 3 ->> 'note', 'incomplete — left March 2023', 'AC2: annotated "incomplete — left March 2023"');
select is(:'tr'::jsonb -> 'sessions' -> 3 -> 'terms_completed', '["First Term", "Mid Term"]'::jsonb, 'AC2: and the completed terms are listed');

-- ── AC3 ───────────────────────────────────────────────────────────────────
select is(:'tr'::jsonb -> 'sessions' -> 6 ->> 'status', 'withheld', 'AC3: the current session is marked withheld');
select is(:'tr'::jsonb -> 'sessions' -> 6 ->> 'note', 'withheld', 'AC3: with the word "withheld" as its note');
select is(jsonb_array_length(:'tr'::jsonb -> 'sessions' -> 6 -> 'subjects'), 0, 'AC3: and no marks disclosed');
select is(:'tr'::jsonb -> 'sessions' -> 0 ->> 'status', 'complete', 'AC3: prior completed sessions still print');
select is(jsonb_array_length(:'tr'::jsonb -> 'sessions' -> 2 -> 'subjects'), 2, 'AC3: with their results');

-- ── a closed campus still renders ─────────────────────────────────────────
reset role;
update public.campus set status = 'archived', deleted_at = now() where id = :'campus_a';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'prin_b_uid')::text, true);
select public.fn_student_transcript(:'st'::uuid) as tr2 \gset
select is(jsonb_array_length(:'tr2'::jsonb -> 'sessions'), 7, 'a closed campus does not drop its sessions');
select is(:'tr2'::jsonb -> 'sessions' -> 0 ->> 'campus_name', 'Old Town Campus (closed)', 'it is named as closed instead');

-- ── who may ───────────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_c'), 'sub', :'prin_c_uid')::text, true);
select throws_ok(format($$select public.fn_student_transcript(%L)$$, :'st'), '42501', null, 'a principal of a campus the student never attended cannot read it');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'clerk_uid')::text, true);
select throws_ok(format($$select public.issue_transcript(%L, 'college admission')$$, :'st'), '42501', null, 'an accountant cannot issue a transcript');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select throws_ok(format($$select public.fn_student_transcript(%L)$$, :'st'), 'P0002', null, 'another school cannot find the student');

-- ── AC4: issuance ─────────────────────────────────────────────────────────
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_b'), 'sub', :'prin_b_uid')::text, true);
select throws_ok(format($$select public.issue_transcript(%L, '  ')$$, :'st'), 'PURPOSE_REQUIRED', 'a purpose is required');
select public.issue_transcript(:'st'::uuid, 'Transfer Certificate') as iss \gset
select matches(:'iss'::jsonb ->> 'serial_no', '^TRN-\d{4}-000001$', 'AC4: the transcript has a serial number');
select is(:'iss'::jsonb -> 'snapshot' ->> 'issued_by_name', 'Tahira Aziz', 'AC4: and the issuing officer''s name');
select is(:'iss'::jsonb -> 'snapshot' ->> 'issued_on', app.fn_karachi_today()::text, 'AC4: and the issue date');
select is((select count(*)::int from public.transcript_issue where serial_no = :'iss'::jsonb ->> 'serial_no' and student_id = :'st'), 1, 'AC4: a matching issuance record exists');
select is((select purpose from public.transcript_issue where id = (:'iss'::jsonb ->> 'issue_id')::uuid), 'Transfer Certificate', 'with its purpose');
select is((:'iss'::jsonb -> 'snapshot' -> 'sessions' -> 3 ->> 'note'), 'incomplete — left March 2023', 'the frozen document carries the annotations');
select is(:'iss'::jsonb ->> 'storage_path', format('%s/%s/%s.pdf', :'tenant_id', :'st', :'iss'::jsonb ->> 'serial_no'), 'the PDF is reserved at {tenant}/{student}/{serial}.pdf');
select public.issue_transcript(:'st'::uuid, 'College admission') as iss2 \gset
select matches(:'iss2'::jsonb ->> 'serial_no', '^TRN-\d{4}-000002$', 'the next serial is the next number, never a reuse');

-- ── the register is append-only ───────────────────────────────────────────
select public.attach_transcript_pdf((:'iss'::jsonb ->> 'issue_id')::uuid, repeat('a', 64)) as _a \gset
select is((select status from public.transcript_issue where id = (:'iss'::jsonb ->> 'issue_id')::uuid), 'issued', 'sealing the PDF marks it issued');
reset role;
select throws_ok(format($$update public.transcript_issue set serial_no = 'TRN-X' where id = %L$$, :'iss'::jsonb ->> 'issue_id'), '42501', null, 'a serial cannot be rewritten');
select throws_ok(format($$delete from public.transcript_issue where id = %L$$, :'iss'::jsonb ->> 'issue_id'), '42501', null, 'and a row cannot be deleted');

-- ── who sees the register ─────────────────────────────────────────────────
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'parent', 'campus_ids', '[]'::jsonb, 'sub', :'parent_uid')::text, true);
select is((select count(*)::int from public.transcript_issue), 1, 'the parent sees only the issued transcript, not the one still being rendered');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'rival_id', 'app_role', 'owner', 'campus_ids', '[]'::jsonb, 'sub', :'rival_uid')::text, true);
select is((select count(*)::int from public.transcript_issue), 0, 'another school sees none');

select * from finish();
rollback;
