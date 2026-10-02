-- pgTAP tests for FR-F02 (Friday shortened schedule / bell calendar rules).
begin;
select plan(17);

select public.provision_tenant('test-bellrule-co', 'Bell Rule Co', 'owner@bellruleco.test');
select id as tenant_id from public.tenant where slug = 'test-bellrule-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset

insert into public.campus (tenant_id, name, code) values (:'tenant_id', 'Girls Campus', 'GIRLS') returning id as girls_campus_id \gset

select gen_random_uuid() as owner_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'owner_user_id', 'owner@bellruleco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'owner_user_id', :'tenant_id', 'owner', 'E2E Owner');

select gen_random_uuid() as teacher_user_id \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'teacher_user_id', 'teacher@bellruleco.test', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'teacher_user_id', :'tenant_id', 'subject_teacher', 'A Teacher');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id', :'girls_campus_id'), 'sub', :'owner_user_id')::text,
  true
);

-- Regular 8-period default template (boys' campus), plus a shortened
-- 6-period Friday template.
select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'REGULAR', 'Regular Day',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40'),
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:40', 'end_time', '09:20')
  ),
  true
) as regular_id \gset

select public.create_bell_template(
  :'campus_id'::uuid, 'MORNING'::public.section_shift, 'FRIDAY', 'Friday Shortened',
  jsonb_build_array(
    jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:30'),
    jsonb_build_object('kind', 'ASSEMBLY', 'start_time', '11:45', 'end_time', '12:30')
  )
) as friday_id \gset

-- The girls' campus only has its own default — no Friday shortening.
select public.create_bell_template(
  :'girls_campus_id'::uuid, 'MORNING'::public.section_shift, 'GREGULAR', 'Girls Regular Day',
  jsonb_build_array(jsonb_build_object('kind', 'TEACHING', 'start_time', '08:00', 'end_time', '08:40')),
  true
) as girls_regular_id \gset

-- ── AC: a campus that does not shorten Friday resolves to its default ──

select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-10'::date),
  :'regular_id'::uuid,
  'AC: with no Friday rule yet, Friday resolves to the campus default (2026-08-10 is a Monday, sanity-checked below too)'
);
select is(
  extract(dow from '2026-08-14'::date)::int,
  5,
  'sanity: 2026-08-14 is indeed a Friday (dow=5) in this codebase''s existing dow convention'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-14'::date),
  :'regular_id'::uuid,
  'before any Friday rule exists, Friday (2026-08-14) also resolves to the default template'
);

-- ── create the Friday weekday rule (weekday=5) ──────────────────────────

select public.create_bell_calendar_rule(:'campus_id'::uuid, 'MORNING'::public.section_shift, :'friday_id'::uuid, 5::smallint) as friday_rule_id \gset

select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-14'::date),
  :'friday_id'::uuid,
  'AC: Friday now resolves to the shortened Friday template'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-10'::date),
  :'regular_id'::uuid,
  'a Monday still resolves to the default template'
);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-21'::date),
  :'friday_id'::uuid,
  'the next Friday (2026-08-21) resolves the same way — this is a recurring weekday rule, not a one-off date'
);

-- ── AC: each campus resolves independently (girls' campus has no rule) ──

select is(
  public.resolve_bell_template(:'girls_campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-14'::date),
  :'girls_regular_id'::uuid,
  'AC: the girls'' campus, with no Friday rule, still resolves Friday to its own default'
);

-- ── BELL_RULE_WEEKDAY_PRECEDENCE_DUPLICATE ───────────────────────────────

select throws_ok(
  format($$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L, 5::smallint) $$, :'campus_id', :'regular_id'),
  'BELL_RULE_WEEKDAY_PRECEDENCE_DUPLICATE',
  'a second weekday=5 rule at the same campus+shift+precedence is rejected as ambiguous'
);

-- A second Friday rule at a HIGHER precedence is allowed and wins.
select public.create_bell_calendar_rule(:'campus_id'::uuid, 'MORNING'::public.section_shift, :'regular_id'::uuid, 5::smallint, null, null, 100::smallint, 'temporary override') as override_rule_id \gset
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-14'::date),
  :'regular_id'::uuid,
  'AC (precedence): a higher-precedence Friday rule overrides the lower-precedence one'
);

select public.delete_bell_calendar_rule(:'override_rule_id'::uuid);
select is(
  public.resolve_bell_template(:'campus_id'::uuid, 'MORNING'::public.section_shift, '2026-08-14'::date),
  :'friday_id'::uuid,
  'deleting the override rule reverts Friday back to the original shortened template'
);

-- ── validation ────────────────────────────────────────────────────────────

select throws_ok(
  format($$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L) $$, :'campus_id', :'regular_id'),
  'BELL_RULE_SHAPE_INVALID',
  'a rule with neither weekday nor date_from is rejected'
);
select throws_ok(
  format($$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L, 9::smallint) $$, :'campus_id', :'regular_id'),
  'BELL_RULE_WEEKDAY_INVALID',
  'a weekday outside 0-6 is rejected'
);
select throws_ok(
  format($$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, gen_random_uuid(), 5::smallint) $$, :'campus_id'),
  'BELL_TEMPLATE_NOT_FOUND',
  'an unknown bell_template id is rejected'
);
select throws_ok(
  format($$ select public.create_bell_calendar_rule(gen_random_uuid(), 'MORNING'::public.section_shift, %L, 5::smallint) $$, :'regular_id'),
  'CAMPUS_NOT_FOUND',
  'an unknown campus id is rejected'
);

-- ── authorization ─────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select throws_ok(
  format($$ select public.create_bell_calendar_rule(%L, 'MORNING'::public.section_shift, %L, 3::smallint) $$, :'campus_id', :'regular_id'),
  'FORBIDDEN',
  'a subject teacher cannot create a bell calendar rule'
);

-- ── RLS ──────────────────────────────────────────────────────────────────

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'subject_teacher', 'campus_ids', json_build_array(:'girls_campus_id'), 'sub', :'teacher_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.bell_calendar_rule where id = :'friday_rule_id'::uuid),
  0,
  'a staff member scoped to a different campus cannot see this campus''s bell calendar rule'
);

select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'), 'sub', :'owner_user_id')::text,
  true
);
select is(
  (select count(*)::int from public.bell_calendar_rule where campus_id = :'campus_id'::uuid),
  1,
  'the owner sees the one surviving rule for this campus (the temporary override was deleted above)'
);

select * from finish();
rollback;
