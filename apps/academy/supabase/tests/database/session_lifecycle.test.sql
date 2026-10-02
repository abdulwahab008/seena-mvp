-- pgTAP tests for FR-A04 (set_current_session, overlap guard) and FR-A05
-- (set_academic_terms).
begin;
select plan(13);

select public.provision_tenant('test-session-co', 'Session Co', 'owner@sessionco.test');
select id as tenant_id from public.tenant where slug = 'test-session-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as seeded_session_id from public.academic_session where tenant_id = :'tenant_id' \gset

-- ── FR-A04: overlap guard (superuser context, no RLS involved) ───────────

select throws_ok(
  format(
    $$ insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
       values (%L, %L, 'Overlapping', %L, %L) $$,
    :'tenant_id', :'campus_id',
    (select (starts_on + 30)::text from public.academic_session where id = :'seeded_session_id'),
    (select (ends_on + 30)::text from public.academic_session where id = :'seeded_session_id')
  ),
  'SESSION_OVERLAP',
  'a session overlapping the seeded one by more than 90 days is rejected'
);

-- A session in a DIFFERENT campus may overlap freely (scoped per campus).
-- Direct insert, not the create_campus() RPC: we're still the superuser
-- setup context here, with no JWT claims yet, so the RPC's own FORBIDDEN
-- check would (correctly) reject it.
insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'BR2', 'Branch Two');
select id as campus2_id from public.campus where tenant_id = :'tenant_id' and code = 'BR2' \gset
select lives_ok(
  format(
    $$ insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
       values (%L, %L, 'Same dates, other campus', %L, %L) $$,
    :'tenant_id', :'campus2_id',
    (select starts_on::text from public.academic_session where id = :'seeded_session_id'),
    (select ends_on::text from public.academic_session where id = :'seeded_session_id')
  ),
  'identical date range in a different campus does not conflict'
);

-- A short (<=90 day) overlap, fully outside the seeded session's range, is allowed.
select lives_ok(
  format(
    $$ insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
       values (%L, %L, 'Slight overlap', %L, %L) $$,
    :'tenant_id', :'campus_id',
    (select (ends_on - 30)::text from public.academic_session where id = :'seeded_session_id'),
    (select (ends_on + 60)::text from public.academic_session where id = :'seeded_session_id')
  ),
  'a 30-day overlap (under the 90-day threshold) is allowed'
);

-- ── FR-A04: set_current_session ───────────────────────────────────────────

insert into public.campus (tenant_id, code, name) values (:'tenant_id', 'CUR', 'Current Test Campus');
select id as campus3_id from public.campus where tenant_id = :'tenant_id' and code = 'CUR' \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
values (:'tenant_id', :'campus3_id', 'Year 1', '2024-01-01', '2024-12-31', true, 'active');
select id as year1_id from public.academic_session where tenant_id = :'tenant_id' and name = 'Year 1' \gset
insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on, is_current, status)
values (:'tenant_id', :'campus3_id', 'Year 2', '2026-01-01', '2026-12-31', false, 'planned');
select id as year2_id from public.academic_session where tenant_id = :'tenant_id' and name = 'Year 2' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus3_id'))::text,
  true
);

select lives_ok(
  format('select public.set_current_session(%L::uuid)', :'year2_id'),
  'an owner can mark a new session current'
);
select is(
  (select is_current from public.academic_session where id = :'year2_id'),
  true,
  'Year 2 is now current'
);
select is(
  (select status::text from public.academic_session where id = :'year1_id'),
  'closed',
  'Year 1 (the previous current session) auto-transitions to closed'
);
select is(
  (select count(*)::int from public.academic_session where campus_id = :'campus3_id' and is_current),
  1,
  'exactly one current session remains for the campus'
);

-- ── FR-A05: set_academic_terms ────────────────────────────────────────────

select throws_ok(
  format(
    $$ select public.set_academic_terms(%L::uuid, '[{"name":"First","starts_on":"2026-01-01","ends_on":"2026-04-30","weightage":30},{"name":"Mid","starts_on":"2026-05-01","ends_on":"2026-08-31","weightage":30},{"name":"Final","starts_on":"2026-09-01","ends_on":"2026-12-31","weightage":35}]'::jsonb) $$,
    :'year2_id'
  ),
  'TERM_WEIGHTAGE_SUM=95',
  'terms summing to 95 (not 100) are rejected and nothing is persisted'
);
select is(
  (select count(*)::int from public.academic_term where session_id = :'year2_id'),
  0,
  'the rejected 95%% batch left zero term rows behind'
);

select lives_ok(
  format(
    $$ select public.set_academic_terms(%L::uuid, '[{"name":"First","starts_on":"2026-01-01","ends_on":"2026-04-30","weightage":30},{"name":"Mid","starts_on":"2026-05-01","ends_on":"2026-08-31","weightage":30},{"name":"Final","starts_on":"2026-09-01","ends_on":"2026-12-31","weightage":40}]'::jsonb) $$,
    :'year2_id'
  ),
  'terms summing to exactly 100 are accepted'
);
select is(
  (select count(*)::int from public.academic_term where session_id = :'year2_id'),
  3,
  'all 3 terms are persisted'
);

-- ── FR-A04: create_academic_session (the authenticated-user entry point) ─

select lives_ok(
  format(
    $$ select public.create_academic_session(%L::uuid, 'Year 3', '2028-01-01', '2028-12-31') $$,
    :'campus3_id'
  ),
  'an owner can create a new session for their own campus'
);
select throws_ok(
  format(
    $$ select public.create_academic_session(%L::uuid, 'Overlaps Year 2', '2026-06-01', '2027-06-01') $$,
    :'campus3_id'
  ),
  'SESSION_OVERLAP',
  'create_academic_session still goes through the same overlap trigger as a direct insert'
);

select * from finish();
rollback;
