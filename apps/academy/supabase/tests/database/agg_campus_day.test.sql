-- pgTAP tests for FR-S01: nightly campus-day aggregate layer.
begin;
select plan(28);

select public.provision_tenant('test-agg-co', 'Agg Co', 'owner@aggco.test');
select id as tenant_id from public.tenant where slug = 'test-agg-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class1_id from public.class_level where tenant_id = :'tenant_id' and code = '1' \gset
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'B2', 'Second Campus') returning id as campus2_id \gset
select public.provision_tenant('test-agg-other', 'Other Agg Co', 'owner@otheraggco.test');
select id as other_tenant_id from public.tenant where slug = 'test-agg-other' \gset

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.set_class_level_active(id, false) from public.class_level where tenant_id = :'tenant_id' and code <> '1';
select public.create_section(:'campus_id'::uuid, :'session_id'::uuid, :'class1_id'::uuid, 'A', 20) as section_id \gset
select public.seed_default_fee_heads(:'tenant_id'::uuid);
select id as tuition_id from public.fee_head where tenant_id = :'tenant_id' and code = 'TUITION' \gset
select public.create_draft_structure(:'campus_id'::uuid, :'session_id'::uuid) as structure_id \gset
select public.add_structure_line(:'structure_id'::uuid, :'class1_id'::uuid, :'tuition_id'::uuid, 500000::bigint, 'monthly'::public.fee_frequency);
select public.publish_fee_structure(:'structure_id'::uuid);
select public.create_student(:'campus_id'::uuid, 'Agg Kid One', '2015-01-01'::date, 'male') as s1 \gset
select public.enrol_student(:'section_id'::uuid, :'s1'::uuid) as e1 \gset
select public.create_student(:'campus_id'::uuid, 'Agg Kid Two', '2015-02-01'::date, 'female') as s2 \gset
select public.enrol_student(:'section_id'::uuid, :'s2'::uuid) as e2 \gset
select public.generate_challans(:'campus_id'::uuid, :'session_id'::uuid, (date_trunc('month', current_date)::date + 14), false);
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(:'e1'::uuid, 500000::bigint, 'cash'::public.fee_payment_mode, 's01-pay', current_date);
reset role;

insert into public.attendance_day (tenant_id, campus_id, session_id, section_id, enrolment_id, attendance_date, status)
values (:'tenant_id', :'campus_id', :'session_id', :'section_id', :'e1', current_date, 'present'),
       (:'tenant_id', :'campus_id', :'session_id', :'section_id', :'e2', current_date, 'absent');

select has_table('public', 'agg_campus_day', 'agg_campus_day exists');
select has_index('public', 'agg_campus_day', 'uq_agg_campus_day', 'AC: unique (campus_id, day) exists');
select has_index('public', 'agg_campus_day', 'idx_agg_tenant_day', 'the tenant/day index exists');
select ok((select bool_and(relrowsecurity) from pg_class where oid in ('public.agg_campus_day'::regclass, 'public.agg_refresh_log'::regclass)), 'RLS on both tables');
select is(has_function_privilege('authenticated', 'public.refresh_agg_campus_day(date,date,uuid)', 'execute'), false, 'a client role cannot trigger a refresh');
select is(has_function_privilege('service_role', 'public.refresh_agg_nightly()', 'execute'), true, 'the nightly job is service_role-only');

-- ── computation ───────────────────────────────────────────────────────────

select is(public.refresh_agg_campus_day(current_date - 30, current_date, :'tenant_id'::uuid), 62, 'a 31-day range for 2 campuses writes 62 rows');
select is((select enrolled_count from public.agg_campus_day where campus_id = :'campus_id' and day = current_date), 2, 'enrolled = 2');
select is((select present_count from public.agg_campus_day where campus_id = :'campus_id' and day = current_date), 1, 'present = 1 (the absent child is not counted)');
select is((select marked_sections from public.agg_campus_day where campus_id = :'campus_id' and day = current_date), 1, 'one section marked');
select is((select collected_paisa from public.agg_campus_day where campus_id = :'campus_id' and day = current_date), 500000::bigint, 'collected = the 5,000 PKR payment');
select is((select outstanding_paisa from public.agg_campus_day where campus_id = :'campus_id' and day = current_date), 500000::bigint, 'outstanding = 10,000 billed - 5,000 paid');
select is((select outstanding_0_30_paisa from public.agg_campus_day where campus_id = :'campus_id' and day = current_date), 500000::bigint, 'a not-yet-due balance sits in the 0-30 bucket');
select is((select count(*)::int from public.agg_campus_day where outstanding_paisa <> outstanding_0_30_paisa + outstanding_31_60_paisa + outstanding_60plus_paisa), 0, 'buckets sum to the total on every row (also a table constraint)');
select is((select collected_paisa from public.agg_campus_day where campus_id = :'campus_id' and day = current_date - 1), 0::bigint, 'a day with nothing posted is zero, not missing');

-- ── incremental: only touched campus-days are recomputed ──────────────────

update public.agg_campus_day set last_refreshed_at = '2000-01-01';
insert into public.agg_refresh_log (tenant_id, job_name, from_date, to_date, status, ran_at)
values (:'tenant_id', 'agg_campus_day_nightly', current_date - 7, current_date - 1, 'ok', now() - interval '1 hour');
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'accountant', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select public.record_payment(:'e2'::uuid, 200000::bigint, 'cash'::public.fee_payment_mode, 's01-backdated', current_date - 20);
reset role;
select public.refresh_agg_nightly();
select is((select collected_paisa from public.agg_campus_day where campus_id = :'campus_id' and day = current_date - 20), 200000::bigint, 'AC: the back-dated receipt lands on its own day');
select is((select last_refreshed_at > '2000-01-01' from public.agg_campus_day where campus_id = :'campus_id' and day = current_date - 20), true, 'and that day was recomputed');
select is((select last_refreshed_at from public.agg_campus_day where campus_id = :'campus_id' and day = current_date - 10), '2000-01-01'::timestamptz, 'AC: an untouched older day was NOT rebuilt');

-- ── failure keeps previous rows, logs, and goes stale after 26 hours ──────

create function pg_temp.fail_agg() returns trigger language plpgsql as $$ begin if current_setting('test.fail_agg', true) = '1' then raise exception 'boom'; end if; return new; end $$;
create trigger trg_fail_agg before insert or update on public.agg_campus_day for each row execute function pg_temp.fail_agg();
update public.agg_campus_day set last_refreshed_at = now() - interval '27 hours';
select set_config('test.fail_agg', '1', true);
select public.refresh_agg_campus_day(current_date - 1, current_date, :'tenant_id'::uuid);
select set_config('test.fail_agg', '0', true);
select is((select count(*)::int from public.agg_refresh_log where tenant_id = :'tenant_id' and status = 'failed' and error = 'boom'), 1, 'AC: a failed refresh writes a failure row');
select is((select count(*)::int from public.agg_campus_day where tenant_id = :'tenant_id' and last_refreshed_at > now() - interval '1 hour'), 0, 'AC: the previous rows are still there, untouched');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select is_stale from public.agg_freshness()), true, 'AC: data older than 26 hours is flagged stale');
reset role;
update public.agg_campus_day set last_refreshed_at = now() - interval '2 hours';
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select is_stale from public.agg_freshness()), false, 'fresh data is not stale');

-- ── RLS: campus_ids claim bounds every role ───────────────────────────────

select is((select count(distinct campus_id)::int from public.agg_campus_day), 1, 'AC: an owner whose token lists 1 of 2 campuses sees 1');
select is((select count(*)::int from public.agg_campus_day where campus_id = :'campus2_id'), 0, 'AC: a tampered campus filter returns nothing');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.agg_campus_day), 0, 'a teacher sees no aggregates');
select set_config('request.jwt.claims', json_build_object('tenant_id', :'other_tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text, true);
select is((select count(*)::int from public.agg_campus_day), 0, 'another school sees none, even claiming this campus');
reset role;

-- ── dashboard query speed: 8 campuses x 400 days ──────────────────────────

insert into public.campus (tenant_id, code, name) select :'tenant_id', 'P' || n, 'Perf ' || n from generate_series(1, 6) n;
insert into public.agg_campus_day (tenant_id, campus_id, day, collected_paisa, billed_paisa, outstanding_paisa, outstanding_0_30_paisa)
select c.tenant_id, c.id, current_date - d, 1000, 2000, 500, 500 from public.campus c, generate_series(100, 500) d where c.tenant_id = :'tenant_id' and c.code like 'P%';
select array_agg(id) as perf_ids from public.campus where tenant_id = :'tenant_id' \gset
set local role authenticated;
select set_config('request.jwt.claims', json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', to_json(:'perf_ids'::uuid[]))::text, true);
do $$
declare t0 timestamptz := clock_timestamp(); n int;
begin
  select count(*) into n from (select campus_id, sum(collected_paisa), sum(billed_paisa), max(day) from public.agg_campus_day where day >= current_date - 500 group by campus_id) q;
  perform set_config('test.perf_ms', (extract(milliseconds from clock_timestamp() - t0))::text, true);
  perform set_config('test.perf_rows', n::text, true);
end $$;
select is(current_setting('test.perf_rows')::int, 8, 'the KPI rollup returns one row per campus (8 campuses)');
select ok(current_setting('test.perf_ms')::numeric < 800, 'AC: the rollup over ~2,800 rows completes in under 800 ms');
reset role;

select * from finish();
rollback;
