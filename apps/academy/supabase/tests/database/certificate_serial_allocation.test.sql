-- pgTAP tests for FR-T02: gapless certificate serial allocation.
--
-- AC1 is tested TWICE and the second one is the real test. pgTAP itself is
-- single-connection, so the sequential run only proves the invariant holds
-- over a long series; the twenty-clerk race is run through dblink, which
-- opens twenty genuinely separate backends and fires their allocations
-- asynchronously (dblink_send_query) before collecting a single result, so
-- they contend for the advisory lock for real. Those twenty sessions
-- cannot see this transaction's uncommitted fixture, so the race gets its
-- own COMMITTED one, created through the same dblink connection. It is not
-- deleted afterwards and cannot be — an append-only counter refuses to be
-- deleted, which is the point of the thing being tested — so the fixture
-- is made repeatable instead: one reusable tenant, plus a fresh campus per
-- run whose series necessarily starts at zero.
--
-- dblink connects back to the server on its own address rather than
-- 127.0.0.1 because pg_hba trusts loopback, and dblink refuses a
-- non-superuser connection whose password was never actually used.
--
-- Every year in the fixture is derived from the clock rather than written
-- out. The acceptance criterion says "2027"; what it means is the year
-- after the one the school is currently in, and provision_tenant() dates
-- its session off current_date, so hard-coding 2026/2027 would quietly rot
-- into a date-drift failure on 1 January.
begin;
select plan(46);

create extension if not exists dblink with schema public;

-- ── fixture ────────────────────────────────────────────────────────────

select extract(year from current_date)::int as y0,
       extract(year from current_date)::int + 1 as y1,
       extract(year from current_date)::int + 2 as y2 \gset

select public.provision_tenant('test-certserial-co', 'Cert Serial Co', 'owner@certserial.test') as tenant_id \gset
select id as campus_a from public.campus where tenant_id = :'tenant_id' \gset
select id as session_y0 from public.academic_session where tenant_id = :'tenant_id' \gset

insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'SOUTH', 'Campus South');
select id as campus_b from public.campus where tenant_id = :'tenant_id' and code = 'SOUTH' \gset

-- Every campus runs its own academic session, so it also runs its own
-- serial series; a serial is only ever numbered against a session its own
-- campus keeps.
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
values (:'tenant_id', :'campus_b', 'south current', make_date(:y0, 1, 1), make_date(:y0, 12, 31));
select id as session_b_y0 from public.academic_session where tenant_id = :'tenant_id' and name = 'south current' \gset

-- The session the school rolls into — AC3's "a new academic year begins".
-- Its starts_on is what the serial's year segment reads.
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
values (:'tenant_id', :'campus_a', 'next year', make_date(:y1, 1, 1), make_date(:y1, 12, 31));
select id as session_y1 from public.academic_session where tenant_id = :'tenant_id' and name = 'next year' \gset

select gen_random_uuid() as admin_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_uid', 'admin@certserial.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_uid', :'tenant_id', 'super_admin', 'Cert Serial Admin');

select is(
  (select extract(year from starts_on)::int from public.academic_session where id = :'session_y0'),
  :y0,
  'the session provision_tenant created is the one the school is in now'
);

-- ── the serial format ──────────────────────────────────────────────────

select is(
  public.format_certificate_serial('TC-{YEAR}-{SEQ}', 2026, 148, 6, 'MAIN'),
  'TC-2026-000148',
  'a serial renders as prefix, year segment and zero-padded sequence'
);
select is(
  public.format_certificate_serial('TC/{CAMPUS}/{YEAR}/{SEQ}', 2027, 1, 5, 'SOUTH'),
  'TC/SOUTH/2027/00001',
  '{CAMPUS} lets a multi-campus tenant tell two identical sequence numbers apart'
);

-- ── AC3: a series starts at one, and the year segment is the session ───

select is(
  public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y0'::uuid),
  'TC-' || :y0 || '-000001',
  'AC3: the first transfer certificate of a session is number one'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0'),
  1::bigint,
  'and the counter row was created by the allocator, not by hand'
);

select public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y0'::uuid) as _s2 \gset
select public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y0'::uuid) as _s3 \gset

select is(
  public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y1'::uuid),
  'TC-' || :y1 || '-000001',
  'AC3: the first TC of the new academic year resets to 000001 and the year segment reads that year'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0'),
  3::bigint,
  'AC3: and the outgoing year keeps its own place in the series, untouched by the rollover'
);

-- FR-T05 reuses this allocator for character certificates on an
-- INDEPENDENT series; certificate_type being part of the key is what
-- gives it that for free.
select is(
  public.allocate_certificate_serial(:'campus_a'::uuid, 'character'::public.certificate_type, :'session_y0'::uuid),
  'CC-' || :y0 || '-000001',
  'a character certificate gets its own series and its own prefix, not the next transfer number'
);

-- Campus is part of the key, exactly as the user story scopes uniqueness.
select is(
  public.allocate_certificate_serial(:'campus_b'::uuid, 'transfer'::public.certificate_type, :'session_b_y0'::uuid),
  'TC-' || :y0 || '-000001',
  'a second campus runs its own series from one, in the same year'
);

-- Two sessions of one campus that both BEGIN in the same calendar year
-- would render the same year segment, i.e. duplicate serials — the other
-- half of AC1's promise. The unique index on (campus, type, academic_year)
-- is what stops it.
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
values (:'tenant_id', :'campus_b', 'south spring', make_date(:y1, 1, 1), make_date(:y1, 6, 30));
select id as session_b_y1a from public.academic_session where tenant_id = :'tenant_id' and name = 'south spring' \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
values (:'tenant_id', :'campus_b', 'south autumn', make_date(:y1, 7, 1), make_date(:y2, 6, 30));
select id as session_b_y1b from public.academic_session where tenant_id = :'tenant_id' and name = 'south autumn' \gset

select is(
  public.allocate_certificate_serial(:'campus_b'::uuid, 'transfer'::public.certificate_type, :'session_b_y1a'::uuid),
  'TC-' || :y1 || '-000001',
  'the first session of the new year opens that campus''s series for it'
);
select throws_ok(
  format($$ select public.allocate_certificate_serial(%L, 'transfer'::public.certificate_type, %L) $$,
         :'campus_b', :'session_b_y1b'),
  '23505',
  null,
  'and a second session opening in the same calendar year cannot own a second counter for the same year segment'
);

-- ── AC1, single connection: the invariant over a long run ─────────────

create temp table serial_run(serial text);
insert into serial_run
select public.allocate_certificate_serial(:'campus_b'::uuid, 'character'::public.certificate_type, :'session_b_y0'::uuid)
  from generate_series(1, 200);

select is(
  (select count(distinct serial)::int from serial_run),
  200,
  'AC1: two hundred sequential allocations produced two hundred distinct serials'
);
select is(
  (select max(seq) - min(seq) + 1 = count(*)
     from (select split_part(serial, '-', 3)::bigint as seq from serial_run) q),
  true,
  'AC1: max(seq) - min(seq) + 1 = count(*) over the whole run — no gaps, no duplicates'
);
select is(
  (select min(split_part(serial, '-', 3)::bigint) from serial_run),
  1::bigint,
  'AC1: the run starts at one'
);

-- ── AC1: the advisory lock is really taken, and is per series ─────────

select 'host=' || host(inet_server_addr()) || ' port=5432 dbname=postgres user=postgres password=postgres' as dsn \gset
select public.dblink_connect('probe', :'dsn') as _c \gset

select hashtextextended('cert-serial:' || :'campus_a' || ':transfer:' || :'session_y0', 0) as tc_lock_key \gset
-- A series this transaction has NOT allocated against, so its lock is free
-- unless the allocator's lock is global rather than per series.
select hashtextextended('cert-serial:' || :'campus_a' || ':bonafide:' || :'session_y0', 0) as bc_lock_key \gset

-- This transaction allocated a transfer serial for campus A above and has
-- not committed, so it still holds that series' xact lock. A different
-- backend must not be able to take it.
select is(
  (select taken from public.dblink('probe',
     format('select pg_try_advisory_xact_lock(%s::bigint)', :'tc_lock_key')) as t(taken boolean)),
  false,
  'AC1: another session cannot enter the same series while an allocation is in flight'
);
select is(
  (select taken from public.dblink('probe',
     format('select pg_try_advisory_xact_lock(%s::bigint)', :'bc_lock_key')) as t(taken boolean)),
  true,
  'AC1: and the lock is per series, so a bonafide certificate is not held up behind a transfer'
);

-- ── AC1: twenty clerks, genuinely at once ─────────────────────────────

-- The race fixture has to be COMMITTED for other backends to see it, and
-- it cannot be tidied away afterwards: deleting the counter row is exactly
-- what this migration forbids, and a tenant's system roles are themselves
-- undeletable (ROLE_IMMUTABLE). So the run is made repeatable instead of
-- reversible — one reusable tenant, and a brand-new campus per run, whose
-- series therefore always starts from zero.
select upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8)) as race_code \gset

-- Walk the committed series up to 147 so the twenty racers must land on
-- exactly 148..167, which is the acceptance criterion verbatim.
select public.dblink_exec('probe', format($q$
  do $b$
  declare
    v_tenant uuid;
    v_campus uuid;
    v_session uuid;
    i int;
  begin
    select id into v_tenant from public.tenant where slug = 'test-certserial-race';
    if v_tenant is null then
      v_tenant := public.provision_tenant('test-certserial-race', 'Serial Race Co', 'owner@serialrace.test');
    end if;

    insert into public.campus (tenant_id, code, name)
    values (v_tenant, %1$L, 'Race Campus ' || %1$L)
    returning id into v_campus;

    insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
    values (v_tenant, v_campus, 'Race ' || %1$L, date_trunc('year', current_date)::date,
            (date_trunc('year', current_date) + interval '1 year' - interval '1 day')::date)
    returning id into v_session;

    for i in 1..147 loop
      perform public.allocate_certificate_serial(v_campus, 'transfer'::public.certificate_type, v_session);
    end loop;
  end
  $b$;
$q$, :'race_code')) as _seed \gset

-- string_agg rather than count(*): an unreferenced subquery column can be
-- pruned by the planner, and these calls ARE the test.
select string_agg(r, ',') as _opened from (
  select public.dblink_connect('clerk' || i, :'dsn') as r from generate_series(1, 20) as i
) c \gset

-- Every send returns immediately, so all twenty statements are in flight
-- against the same counter row before the first result is collected.
select string_agg(r::text, ',') as _sent from (
  select public.dblink_send_query('clerk' || i, format($q$
    select public.allocate_certificate_serial(c.id, 'transfer'::public.certificate_type, s.id)
      from public.campus c
      join public.academic_session s on s.campus_id = c.id
     where c.code = %L
  $q$, :'race_code')) as r from generate_series(1, 20) as i
) s \gset

create temp table race_result(serial text);
do $$
declare
  i int;
begin
  for i in 1..20 loop
    execute format('insert into pg_temp.race_result select * from public.dblink_get_result(%L) as t(s text)', 'clerk' || i);
    -- dblink hands back an empty set once per finished query; draining it
    -- is what lets the connection be closed cleanly.
    execute format('select * from public.dblink_get_result(%L) as t(s text)', 'clerk' || i);
    perform public.dblink_disconnect('clerk' || i);
  end loop;
end;
$$;

select is(
  (select count(*)::int from race_result),
  20,
  'AC1: twenty concurrent clerks each came away with a serial'
);
select is(
  (select count(distinct serial)::int from race_result),
  20,
  'AC1: zero duplicates across twenty concurrent transactions'
);
select is(
  (select min(split_part(serial, '-', 3)::bigint) from race_result),
  148::bigint,
  'AC1: the race began at 000148'
);
select is(
  (select max(split_part(serial, '-', 3)::bigint) from race_result),
  167::bigint,
  'AC1: and ended at 000167'
);
select is(
  (select max(seq) - min(seq) + 1 = count(*)
     from (select split_part(serial, '-', 3)::bigint as seq from race_result) q),
  true,
  'AC1: max(seq) - min(seq) + 1 = count(*) across the twenty racers — zero gaps'
);
select is(
  (select current_value from public.dblink('probe', format($q$
     select ctr.current_value
       from public.certificate_serial_counter ctr
       join public.campus c on c.id = ctr.campus_id
      where c.code = %L and ctr.certificate_type = 'transfer'
   $q$, :'race_code')) as t(current_value bigint)),
  167::bigint,
  'AC1: and the committed counter agrees with the highest serial handed out'
);

select public.dblink_disconnect('probe') as _dc \gset

-- ── AC2: a failure after allocation returns the number ────────────────

select current_value as before_rollback from public.certificate_serial_counter
 where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0' \gset

savepoint before_issue;
select public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y0'::uuid) as doomed_serial \gset
-- ... and here the PDF render blows up.
rollback to savepoint before_issue;

select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0'),
  :'before_rollback'::bigint,
  'AC2: the counter is NOT advanced by an allocation whose transaction rolled back'
);
select is(
  public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y0'::uuid),
  :'doomed_serial',
  'AC2: and the next issue is handed exactly the number the failed one gave up'
);

-- The shape a real issue path has: allocation and the render that fails
-- both inside a plpgsql BEGIN…EXCEPTION block, which is a savepoint. The
-- handler runs in the still-live outer transaction, so the failure can be
-- reported without taking the serial with it.
select current_value as before_subxact from public.certificate_serial_counter
 where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0' \gset

do $$
declare
  v_campus uuid;
  v_session uuid;
begin
  select c.id, s.id into v_campus, v_session
    from public.tenant t
    join public.campus c on c.tenant_id = t.id and c.code = 'MAIN'
    join public.academic_session s on s.tenant_id = t.id and s.name = 'next year'
   where t.slug = 'test-certserial-co';
  begin
    perform public.allocate_certificate_serial(v_campus, 'transfer'::public.certificate_type, v_session);
    raise exception 'PDF_RENDER_FAILED';
  exception when others then
    null;
  end;
end;
$$;

select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y1'),
  1::bigint,
  'AC2: a subtransaction that fails after allocating leaves the counter exactly where it was'
);
select is(
  public.allocate_certificate_serial(:'campus_a'::uuid, 'transfer'::public.certificate_type, :'session_y1'::uuid),
  'TC-' || :y1 || '-000002',
  'AC2: so the number the failed render burned is handed straight back out'
);

-- No sequence was harmed in the making of this register: a nextval-backed
-- allocator would have left a hole above, and would also be visible here.
select is(
  (select count(*)::int from pg_class
    where relkind = 'S' and relname ilike '%certificate%serial%'),
  0,
  'AC2: the allocator is not backed by a sequence, whose advance would survive the rollback'
);

-- ── AC4: the counter is append-only ───────────────────────────────────

select current_value as guarded_value from public.certificate_serial_counter
 where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'super_admin', 'campus_ids',
                    json_build_array(:'campus_a', :'campus_b'), 'sub', :'admin_uid')::text,
  true
);

select isnt_empty(
  format($$ select 1 from public.certificate_serial_counter where campus_id = %L $$, :'campus_a'),
  'a Super Admin can READ the counters — the register administrator is meant to watch them'
);
select lives_ok(
  format($$ update public.certificate_serial_counter set current_value = 9999 where campus_id = %L $$, :'campus_a'),
  'AC4: a Super Admin''s direct UPDATE is filtered out by RLS before it can touch a row'
);
select throws_ok(
  format($$ insert into public.certificate_serial_counter (tenant_id, campus_id, certificate_type, session_id, academic_year, prefix_pattern)
            values (%L, %L, 'bonafide', %L, 2026, 'BC-{YEAR}-{SEQ}') $$,
         :'tenant_id', :'campus_a', :'session_y0'),
  '42501',
  null,
  'AC4: and cannot insert a counter row of their own either'
);
select throws_ok(
  $$ select public.allocate_certificate_serial(
       (select id from public.campus where code = 'MAIN' limit 1),
       'transfer'::public.certificate_type, null) $$,
  '42501',
  null,
  'AC4: the allocator itself is not callable by a signed-in user, so no serial can be burned without a certificate'
);

reset role;
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0'),
  :'guarded_value'::bigint,
  'AC4: the counter is exactly where it was'
);

-- service_role holds BYPASSRLS and every DML grant, so RLS is not the last
-- word — the trigger is, and it is the trigger that speaks the message.
set local role service_role;
select throws_ok(
  format($$ update public.certificate_serial_counter set current_value = 9999 where campus_id = %L $$, :'campus_a'),
  '42501',
  'serial counters are append-only via allocate_certificate_serial()',
  'AC4: a caller that bypasses RLS entirely is blocked by the trigger, by name'
);
select throws_ok(
  format($$ update public.certificate_serial_counter set current_value = current_value - 1 where campus_id = %L $$, :'campus_a'),
  '42501',
  'serial counters are append-only via allocate_certificate_serial()',
  'AC4: rewinding the counter by one is refused just as flatly as jumping it'
);
select throws_ok(
  format($$ delete from public.certificate_serial_counter where campus_id = %L $$, :'campus_a'),
  '42501',
  'serial counters are append-only via allocate_certificate_serial()',
  'AC4: and the counter row cannot be deleted, which would restart the series'
);
select throws_ok(
  format($$ insert into public.certificate_serial_counter (tenant_id, campus_id, certificate_type, session_id, academic_year, prefix_pattern, current_value)
            values (%L, %L, 'bonafide', %L, 2026, 'BC-{YEAR}-{SEQ}', 5000) $$,
         :'tenant_id', :'campus_a', :'session_y0'),
  '42501',
  'serial counters are append-only via allocate_certificate_serial()',
  'AC4: a series cannot be seeded part-way up, so it always begins at one'
);
reset role;

-- The trigger's allow-list is a call-stack check, not a magic value a
-- caller could set: a hand-written UPDATE of exactly +1 is still refused.
select throws_ok(
  format($$ update public.certificate_serial_counter set current_value = current_value + 1 where campus_id = %L and certificate_type = 'transfer' and session_id = %L $$,
         :'campus_a', :'session_y0'),
  '42501',
  'serial counters are append-only via allocate_certificate_serial()',
  'AC4: even an increment of exactly one is refused when it does not come from the allocator'
);
select is(
  (select current_value from public.certificate_serial_counter
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0'),
  :'guarded_value'::bigint,
  'AC4: after every attempt above, the counter still reads what the allocator left'
);

-- The frozen columns are frozen: an activated series cannot be repointed
-- or reformatted, which is what would make an issued serial unreproducible.
select throws_ok(
  format($$ update public.certificate_serial_counter set prefix_pattern = 'XX-{SEQ}' where campus_id = %L and certificate_type = 'transfer' and session_id = %L $$,
         :'campus_a', :'session_y0'),
  '42501',
  'serial counters are append-only via allocate_certificate_serial()',
  'AC4: the serial format of a live series cannot be rewritten under it'
);

-- ── scope ──────────────────────────────────────────────────────────────

select throws_ok(
  format($$ select public.allocate_certificate_serial(%L, 'transfer'::public.certificate_type, %L) $$,
         :'campus_b', :'session_y1'),
  'P0002',
  'ACADEMIC_SESSION_NOT_FOUND',
  'a session belonging to another campus is not a session this campus can number against'
);
select throws_ok(
  format($$ select public.allocate_certificate_serial(%L, 'transfer'::public.certificate_type, null) $$,
         gen_random_uuid()),
  'P0002',
  'CAMPUS_NOT_FOUND',
  'and an unknown campus allocates nothing'
);

-- ── the register view ──────────────────────────────────────────────────

select is(
  (select next_serial from public.v_certificate_serial_register
    where campus_id = :'campus_a' and certificate_type = 'transfer' and session_id = :'session_y0'),
  public.format_certificate_serial('TC-{YEAR}-{SEQ}', :y0, :'guarded_value'::bigint + 1, 6, 'MAIN'),
  'the register view shows the number the next certificate will carry'
);
select is(
  (select last_serial from public.v_certificate_serial_register
    where campus_id = :'campus_a' and certificate_type = 'character' and session_id = :'session_y0'),
  'CC-' || :y0 || '-000001',
  'and the last one it handed out'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'principal', 'campus_ids',
                    json_build_array(:'campus_b'), 'sub', :'admin_uid')::text,
  true
);
select is(
  (select count(*)::int from public.v_certificate_serial_register where campus_id = :'campus_a'),
  0,
  'a Principal scoped to one campus cannot read another campus''s counters through the view'
);
select isnt_empty(
  format($$ select 1 from public.v_certificate_serial_register where campus_id = %L $$, :'campus_b'),
  'but sees their own'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'teacher', 'campus_ids',
                    json_build_array(:'campus_a', :'campus_b'), 'sub', :'admin_uid')::text,
  true
);
select is(
  (select count(*)::int from public.certificate_serial_counter),
  0,
  'and a Teacher sees no counters at all'
);
reset role;

select * from finish();
rollback;
