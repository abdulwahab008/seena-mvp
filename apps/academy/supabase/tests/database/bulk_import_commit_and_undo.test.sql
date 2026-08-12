-- pgTAP tests for FR-C15: commit a bulk student import atomically, with an
-- error report.
--
-- Scale note, same as FR-C14's suite: the AC's 4,882-row file is
-- illustrative scale. Nothing below changes shape between 55 rows and
-- 4,882 - the GR block is one UPDATE either way, the loop is the same
-- loop, and the subtransaction that makes AC4 work does not care how many
-- rows it is discarding. 55/50/60/10-row batches keep the suite under a
-- second.
--
-- Each AC gets its own campus, because the interesting state (the campus
-- GR counter, section seats) is per-campus and the ACs would otherwise
-- read each other's leftovers:
--   campus A - AC1 (exact counts, marked committed) + AC2 (double commit)
--   campus B - AC3 (historical GR numbers, counter advanced past them)
--   campus C - AC4 (mid-batch constraint violation)
--   campus D - AC5, refused: a fee row references an imported student
--   campus E - AC5, allowed inside the window, then refused outside it
begin;
select plan(61);

select public.provision_tenant('test-c15-co', 'C15 Co', 'owner@c15.test');
select id as tenant_id from public.tenant where slug = 'test-c15-co' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset

select public.provision_tenant('test-c15-other-co', 'C15 Other Co', 'owner@c15other.test');
select id as other_tenant_id from public.tenant where slug = 'test-c15-other-co' \gset
select id as other_campus_id from public.campus where tenant_id = :'other_tenant_id' \gset

-- Tenant-wide (campus_id null) so every campus below can import into it.
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, status)
values (:'tenant_id', null, 'C15 Session', current_date - 30, current_date + 300, 'active')
returning id as session_id \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus A', 'CA') returning id as campus_a \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus B', 'CB') returning id as campus_b \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus C', 'CC') returning id as campus_c \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus D', 'CD') returning id as campus_d \gset
insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Campus E', 'CE') returning id as campus_e \gset

insert into public.class_section (tenant_id, campus_id, session_id, class_level_id, name, capacity)
select :'tenant_id', c.id, :'session_id'::uuid, :'class1_id'::uuid, 'A', 200
  from public.campus c where c.tenant_id = :'tenant_id' and c.code in ('CA', 'CB', 'CC', 'CD', 'CE');

-- ── app.fn_gr_ordinal: what moves the campus counter and what does not ──

select is(app.fn_gr_ordinal('CB', '8450'), 8450::bigint, 'a bare historical number is read as its own ordinal');
select is(app.fn_gr_ordinal('CB', 'CB-008450'), 8450::bigint, 'a prefixed, zero-padded number is read the same way');
select is(app.fn_gr_ordinal('CB', 'REG/7-B'), null, 'a free-form paper reference has no ordinal, so it cannot move the counter');

-- Builds a batch of p_ok importable rows (+ p_bad blocked ones) and
-- finalises it, exactly as the app layer does.
create function pg_temp.build_batch(
  p_campus uuid, p_session uuid, p_class uuid, p_ok int, p_bad int, p_gr_from bigint default null
)
returns uuid
language plpgsql
as $$
declare
  v_batch uuid;
  v_rows  jsonb;
begin
  v_batch := (public.create_import_batch(p_campus, p_session, 'register.csv') ->> 'batch_id')::uuid;

  select jsonb_agg(jsonb_build_object(
           'row_no', g,
           'raw', jsonb_build_object('class', '1', 'name_en', 'Student ' || g),
           'normalised', jsonb_build_object(
             'name_en', 'Student ' || g,
             'dob', '2016-01-01',
             'gender', case when g % 2 = 0 then 'male' else 'female' end,
             'class_level_id', p_class,
             'gr_number', case when p_gr_from is null then null else (p_gr_from + g - 2)::text end
           ),
           'errors', '[]'::jsonb
         ) order by g)
    into v_rows
    from generate_series(2, p_ok + 1) g;
  perform public.stage_import_rows(v_batch, coalesce(v_rows, '[]'::jsonb));

  if p_bad > 0 then
    select jsonb_agg(jsonb_build_object(
             'row_no', g,
             'raw', jsonb_build_object('class', 'Class One'),
             'normalised', jsonb_build_object('name_en', 'Blocked ' || g, 'dob', '2016-01-01', 'gender', 'male'),
             'errors', jsonb_build_array(jsonb_build_object(
               'column', 'class', 'code', 'UNKNOWN_CLASS', 'severity', 'error',
               'message', 'Unknown class ''Class One'' - expected one of NUR, KG, 1..12'))
           ) order by g)
      into v_rows
      from generate_series(p_ok + 2, p_ok + p_bad + 1) g;
    perform public.stage_import_rows(v_batch, v_rows);
  end if;

  perform public.finalise_import_batch(v_batch);
  return v_batch;
end;
$$;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text,
  true
);

-- ══ AC1 + AC2 (campus A): 55 importable rows, 5 blocked ═════════════════

select pg_temp.build_batch(:'campus_a'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 55, 5) as batch_a \gset

select is(
  (select ok_rows || '/' || error_rows from public.import_batch where id = :'batch_a'::uuid),
  '55/5',
  'the batch arrives at commit already counted by FR-C14'
);

select public.commit_import_batch(:'batch_a'::uuid) as commit_a \gset

select is(((:'commit_a')::jsonb ->> 'ok')::boolean, true, 'the commit reports success');
select is(((:'commit_a')::jsonb ->> 'committed_rows')::int, 55, 'AC1: the commit reports exactly the importable row count');

select is(
  (select count(*)::int from public.student where campus_id = :'campus_a'::uuid),
  55,
  'AC1: exactly one student per importable row exists'
);
select is(
  (select count(*)::int from public.enrolment where campus_id = :'campus_a'::uuid and session_id = :'session_id'::uuid),
  55,
  'AC1: and exactly one enrolment per student'
);
select is(
  (select count(*)::int from public.section_membership_history h
     join public.enrolment e on e.id = h.enrolment_id
    where e.campus_id = :'campus_a'::uuid),
  55,
  'each enrolment gets the section history row enrol_student() would have written'
);
select is(
  (select count(*)::int from public.gr_ledger where campus_id = :'campus_a'::uuid),
  55,
  'every committed student is on the permanent GR register'
);

select is(
  (select commit_state from public.v_import_batch where id = :'batch_a'::uuid),
  'committed',
  'AC1: the batch is marked committed'
);
select isnt(
  (select committed_at from public.import_batch where id = :'batch_a'::uuid),
  null,
  'AC1: with a timestamp'
);
select is(
  (select undo_deadline - committed_at from public.import_batch where id = :'batch_a'::uuid),
  interval '24 hours',
  'and a 24-hour undo deadline measured from it'
);
select isnt(
  (select error_report_path from public.import_batch where id = :'batch_a'::uuid),
  null,
  'a batch with blocked rows gets a failure-report object path reserved for it'
);
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_a'::uuid and student_id is not null),
  55,
  'every committed row records the student it created, so undo knows what to take back'
);

-- The 55 rows supplied no GR number of their own, so they consume the
-- allocated block CA-000001..CA-000055 and leave the counter at 56.
select is(
  (select count(*)::int from public.student
    where campus_id = :'campus_a'::uuid and gr_number between 'CA-000001' and 'CA-000055'),
  55,
  'rows with no GR number of their own get one contiguous allocated block'
);
select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_a'::uuid),
  56::bigint,
  'the campus counter advanced by exactly the number of rows that needed a number'
);

-- AC2
select throws_ok(
  format($$select public.commit_import_batch(%L::uuid)$$, :'batch_a'),
  'IMPORT_BATCH_ALREADY_COMMITTED',
  'AC2: the second commit of the same batch id is rejected'
);
select is(
  (select count(*)::int from public.student where campus_id = :'campus_a'::uuid),
  55,
  'AC2: and creates no duplicate students'
);

-- ══ AC3 (campus B): the school's own historical numbers ═════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_b'))::text,
  true
);

select pg_temp.build_batch(:'campus_b'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 50, 0, 8401::bigint) as batch_b \gset
select public.commit_import_batch(:'batch_b'::uuid) as commit_b \gset

select is(((:'commit_b')::jsonb ->> 'ok')::boolean, true, 'a file that supplies its own GR numbers commits');
select is(
  (select count(*)::int from public.gr_ledger
    where campus_id = :'campus_b'::uuid and gr_number in ('8401', '8450')),
  2,
  'AC3: the school''s historical GR numbers are written into gr_ledger verbatim'
);
select is(
  (select count(*)::int from public.gr_ledger where campus_id = :'campus_b'::uuid),
  50,
  'AC3: all of them, not just the ones that happened to be allocated'
);
select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_b'::uuid),
  8451::bigint,
  'AC3: the campus counter advances to one past the highest number the file supplied'
);
select is(
  (select count(*)::int from public.student where campus_id = :'campus_b'::uuid and gr_number like 'CB-%'),
  0,
  'AC3: and no number was allocated from the block, because every row brought its own'
);

-- The next import on that campus must start ABOVE the historical numbers,
-- or an allocated number would collide with one already on the register.
select pg_temp.build_batch(:'campus_b'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 2, 0) as batch_b2 \gset
select public.commit_import_batch(:'batch_b2'::uuid);

select is(
  (select array_agg(gr_number order by gr_number)::text[] from public.student
    where campus_id = :'campus_b'::uuid and gr_number like 'CB-%'),
  array['CB-008451', 'CB-008452'],
  'a later allocation starts above every historical number the earlier file supplied'
);
select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_b'::uuid),
  8453::bigint,
  'and leaves the counter where the next allocation should pick up'
);

-- ══ AC4 (campus C): a constraint violation mid-batch ════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_c'))::text,
  true
);

select pg_temp.build_batch(:'campus_c'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 60, 0) as batch_c \gset

-- Row 35's date of birth is outside student.chk_dob_reasonable. It is
-- planted after validation on purpose: this is the class of failure that
-- can only be found by actually writing the row, which is the whole point
-- of the AC.
reset role;
update public.import_row
   set normalised = jsonb_set(normalised, '{dob}', '"1990-01-01"')
 where batch_id = :'batch_c'::uuid and row_no = 35;
set local role authenticated;

select public.commit_import_batch(:'batch_c'::uuid) as commit_c \gset

select is(((:'commit_c')::jsonb ->> 'ok')::boolean, false, 'AC4: the commit reports failure rather than partial success');
select is(((:'commit_c')::jsonb ->> 'failed_row_no')::int, 35, 'AC4: and names the offending row');

select is(
  (select count(*)::int from public.student where campus_id = :'campus_c'::uuid),
  0,
  'AC4: the ENTIRE batch rolled back - not one of the 34 rows before the bad one survives'
);
select is(
  (select count(*)::int from public.enrolment where campus_id = :'campus_c'::uuid),
  0,
  'AC4: no partial enrolments either'
);
select is(
  (select count(*)::int from public.gr_ledger where campus_id = :'campus_c'::uuid),
  0,
  'AC4: and nothing was written to the permanent GR register'
);
select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_c'::uuid),
  1::bigint,
  'AC4: the GR block allocation rolled back too - the counter never moved'
);

select is(
  (select commit_state from public.v_import_batch where id = :'batch_c'::uuid),
  'failed',
  'AC4: the batch is marked failed - the marking survived the rollback that discarded the data'
);
select is(
  (select failed_row_no from public.import_batch where id = :'batch_c'::uuid),
  35,
  'AC4: with the offending row recorded on the batch'
);
select ok(
  (select failed_message from public.import_batch where id = :'batch_c'::uuid) like '%chk_dob_reasonable%',
  'AC4: and the message that actually stopped it'
);

-- A failed commit leaves the batch validated, so fixing the cause and
-- re-committing is the natural next move.
reset role;
update public.import_row
   set normalised = jsonb_set(normalised, '{dob}', '"2016-01-01"')
 where batch_id = :'batch_c'::uuid and row_no = 35;
set local role authenticated;

select public.commit_import_batch(:'batch_c'::uuid) as recommit_c \gset
select is(((:'recommit_c')::jsonb ->> 'ok')::boolean, true, 'the same batch commits once the cause is fixed');
select is(
  (select count(*)::int from public.student where campus_id = :'campus_c'::uuid),
  60,
  'and lands all 60 rows the second time'
);
select is(
  (select failed_at from public.import_batch where id = :'batch_c'::uuid),
  null,
  'the stale failure marking is cleared by the successful retry'
);

-- ══ AC5 (campus D): undo refused once anything depends on the import ════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_d'))::text,
  true
);

select pg_temp.build_batch(:'campus_d'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 10, 0) as batch_d \gset
select public.commit_import_batch(:'batch_d'::uuid);
select enrolment_id as dep_enrolment from public.import_row
 where batch_id = :'batch_d'::uuid and enrolment_id is not null limit 1 \gset

reset role;
insert into public.fee_ledger (tenant_id, campus_id, enrolment_id, session_id, entry_type, amount_paisa, direction)
values (:'tenant_id', :'campus_d', :'dep_enrolment', :'session_id', 'charge', 500000, 'debit');
set local role authenticated;

select throws_ok(
  format($$select public.undo_import_batch(%L::uuid)$$, :'batch_d'),
  'UNDO_BLOCKED_BY_DEPENDENCY',
  'AC5: once a fee row references an imported student, the undo is refused'
);
select is(
  (select count(*)::int from public.student where campus_id = :'campus_d'::uuid),
  10,
  'AC5: and the refused undo leaves every imported student in place'
);

-- ══ AC5 (campus E): undo inside the window, refused outside it ══════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_e'))::text,
  true
);

select pg_temp.build_batch(:'campus_e'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 10, 0) as batch_e \gset
select public.commit_import_batch(:'batch_e'::uuid);

select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_e'::uuid),
  11::bigint,
  'the commit consumed a block of 10 numbers on this campus'
);

select public.undo_import_batch(:'batch_e'::uuid) as undo_e \gset

select is(((:'undo_e')::jsonb ->> 'ok')::boolean, true, 'AC5: an undo inside 24 hours with no dependencies succeeds');
select is(
  (select count(*)::int from public.student where campus_id = :'campus_e'::uuid),
  0,
  'AC5: the imported students are gone'
);
select is(
  (select count(*)::int from public.enrolment where campus_id = :'campus_e'::uuid),
  0,
  'AC5: and their enrolments with them'
);
select is(
  (select count(*)::int from public.gr_ledger where campus_id = :'campus_e'::uuid),
  0,
  'AC5: the GR numbers are released back off the register'
);
select is(
  (select next_value from public.gr_sequence where campus_id = :'campus_e'::uuid),
  1::bigint,
  'AC5: and the campus counter is rewound, because nobody else took a number in between'
);
select is(
  (select commit_state from public.v_import_batch where id = :'batch_e'::uuid),
  'undone',
  'AC5: the batch is marked undone'
);
select throws_ok(
  format($$select public.commit_import_batch(%L::uuid)$$, :'batch_e'),
  'IMPORT_BATCH_UNDONE',
  'an undone batch cannot be re-committed - re-upload the file instead'
);

select pg_temp.build_batch(:'campus_e'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 10, 0) as batch_e2 \gset
select public.commit_import_batch(:'batch_e2'::uuid);

reset role;
update public.import_batch
   set committed_at = now() - interval '25 hours', undo_deadline = now() - interval '1 hour'
 where id = :'batch_e2'::uuid;
set local role authenticated;

select throws_ok(
  format($$select public.undo_import_batch(%L::uuid)$$, :'batch_e2'),
  'UNDO_WINDOW_EXPIRED',
  'AC5: after 24 hours the undo is refused even with no dependencies at all'
);
select is(
  (select count(*)::int from public.student where campus_id = :'campus_e'::uuid),
  10,
  'AC5: and the students stay'
);

-- ══ role and campus gating ══════════════════════════════════════════════

select pg_temp.build_batch(:'campus_e'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 2, 0) as batch_gate \gset

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids', json_build_array(:'campus_e'))::text,
  true
);
select throws_ok(
  format($$select public.commit_import_batch(%L::uuid)$$, :'batch_gate'),
  'FORBIDDEN',
  'a teacher cannot commit a bulk student import'
);

-- An admissions officer may commit one, but not silently erase one: the
-- same asymmetry FR-A15 drew between soft_delete and restore_record.
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_e'))::text,
  true
);
select throws_ok(
  format($$select public.undo_import_batch(%L::uuid)$$, :'batch_e2'),
  'FORBIDDEN',
  'an admissions officer cannot undo an import'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids', json_build_array(:'campus_a'))::text,
  true
);
select throws_ok(
  format($$select public.commit_import_batch(%L::uuid)$$, :'batch_gate'),
  'FORBIDDEN',
  'a principal cannot commit a batch belonging to a campus outside their scope'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'other_campus_id'))::text,
  true
);
select throws_ok(
  format($$select public.commit_import_batch(%L::uuid)$$, :'batch_gate'),
  'IMPORT_BATCH_NOT_FOUND',
  'another tenant''s owner cannot even see the batch, let alone commit it'
);

-- ══ purge_import_staging ════════════════════════════════════════════════

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_a'))::text,
  true
);

reset role;
update public.import_batch set created_at = now() - interval '40 days'
 where id in (:'batch_a'::uuid, :'batch_gate'::uuid);
set local role authenticated;

select public.purge_import_staging() as purge \gset

select is(((:'purge')::jsonb ->> 'rows_deleted')::int, 2, 'a batch that never committed has its staged rows deleted outright');
select is(((:'purge')::jsonb ->> 'rows_scrubbed')::int, 60, 'a committed batch keeps its rows but loses the spreadsheet cells');
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_a'::uuid and student_id is not null),
  55,
  'the link from a live student back to the file they arrived in survives the scrub'
);
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_a'::uuid and raw <> '{}'::jsonb),
  0,
  'but not one cell of the school''s spreadsheet does'
);
select is(
  (select count(*)::int from public.import_row where batch_id = :'batch_gate'::uuid),
  0,
  'and the never-committed batch has no staged rows left at all'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'admissions_officer', 'campus_ids', json_build_array(:'campus_a'))::text,
  true
);
select throws_ok(
  $$select public.purge_import_staging()$$,
  'FORBIDDEN',
  'retention is an Owner-level job, not something an admissions officer runs'
);

reset role;
select is(
  (select b.public::text from storage.buckets b where b.id = 'import-errors'),
  'false',
  'the failure-report bucket is private'
);

select * from finish();
rollback;
