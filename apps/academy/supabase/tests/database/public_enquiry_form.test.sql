-- pgTAP tests for FR-B02: public self-service web enquiry form.
begin;
select plan(18);

select public.provision_tenant('test-public-enquiry-co', 'Public Enquiry Co', 'owner@publicenquiryco.test');
select id as tenant_id from public.tenant where slug = 'test-public-enquiry-co' \gset

-- ── validation ───────────────────────────────────────────────────────

set local role anon;

select throws_ok(
  $$ select public.submit_public_enquiry('unknown-slug-xyz', 'Child', '2020-01-01'::date, '1', 'Parent', '03001111111', 'ip-a') $$,
  'TENANT_NOT_FOUND',
  'AC: an unknown tenant slug is refused with no row written under any tenant'
);

-- ── fn_public_school_info: what the public form itself needs to render ─

select throws_ok(
  $$ select public.fn_public_school_info('unknown-slug-xyz') $$,
  'TENANT_NOT_FOUND',
  'the school-info lookup also refuses an unknown slug'
);
select (public.fn_public_school_info('test-public-enquiry-co')) as school_info \gset
select is(
  (:'school_info')::jsonb ->> 'tenant_name',
  'Public Enquiry Co',
  'the school-info lookup exposes the tenant''s public name'
);
select is(
  jsonb_array_length((:'school_info')::jsonb -> 'class_levels'),
  14,
  'the default 14 class levels are exposed as options for the public form'
);

select throws_ok(
  format('select public.submit_public_enquiry(%L, %L, %L, %L, %L, %L, %L)', 'test-public-enquiry-co', 'Child', '2020-01-01'::date, '1', 'Parent', 'not-a-phone', 'ip-a'),
  'PHONE_INVALID',
  'a malformed phone number is refused'
);

select throws_ok(
  format('select public.submit_public_enquiry(%L, %L, %L, %L, %L, %L, %L)', 'test-public-enquiry-co', 'Child', '2020-01-01'::date, 'ZZZ', 'Parent', '03001111111', 'ip-a'),
  'CLASS_LEVEL_NOT_FOUND',
  'an unknown class code is refused'
);

-- AC-adjacent: a Nursery enquiry below the 2y6m-by-1-April floor has no
-- staff to exercise an override, so it is a hard rejection.
select throws_ok(
  format('select public.submit_public_enquiry(%L, %L, %L, %L, %L, %L, %L)', 'test-public-enquiry-co', 'Toddler', (current_date - interval '1 year')::date, 'NUR', 'Parent', '03001112222', 'ip-a'),
  'AGE_BELOW_MINIMUM',
  'an underage Nursery enquiry is refused with no override path for an anonymous submission'
);

-- ── a valid submission ───────────────────────────────────────────────

select (public.submit_public_enquiry('test-public-enquiry-co', 'Web Child', '2020-01-01'::date, '1', 'Web Parent', '0300-111-3333', 'ip-b', 'ویب چائلڈ', true)) as result1 \gset
select ok((:'result1')::jsonb ->> 'enquiry_id' is not null, 'a valid submission succeeds');

-- admission_enquiry has no anon read grants of any kind (by design — the
-- same property the FR demands for writes) — verify the written row from
-- a trusted context, same as querying it straight from the database.
reset role;
select is(
  (select source from public.admission_enquiry where id = ((:'result1')::jsonb ->> 'enquiry_id')::uuid)::text,
  'web',
  'the enquiry is recorded with source = web'
);
select is(
  (select phone_e164 from public.admission_enquiry where id = ((:'result1')::jsonb ->> 'enquiry_id')::uuid),
  '+923001113333',
  'the phone number is normalized regardless of the punctuation the visitor typed'
);
select is(
  (select child_name_ur from public.admission_enquiry where id = ((:'result1')::jsonb ->> 'enquiry_id')::uuid),
  'ویب چائلڈ',
  'AC: Urdu script is accepted into child_name_ur'
);
select is(
  (select whatsapp_opt_in from public.admission_enquiry where id = ((:'result1')::jsonb ->> 'enquiry_id')::uuid),
  true,
  'the WhatsApp opt-in flag is recorded'
);
set local role anon;

-- ── AC: a 6th submission from the same phone within 60 minutes is
--    refused, with no row written ───────────────────────────────────

select public.submit_public_enquiry('test-public-enquiry-co', 'Sib 2', '2020-01-02'::date, '1', 'Web Parent', '03001113333', 'ip-c');
select public.submit_public_enquiry('test-public-enquiry-co', 'Sib 3', '2020-01-03'::date, '1', 'Web Parent', '03001113333', 'ip-c');
select public.submit_public_enquiry('test-public-enquiry-co', 'Sib 4', '2020-01-04'::date, '1', 'Web Parent', '03001113333', 'ip-c');
select public.submit_public_enquiry('test-public-enquiry-co', 'Sib 5', '2020-01-05'::date, '1', 'Web Parent', '03001113333', 'ip-c');
reset role;
select is(
  (select count(*)::int from public.admission_enquiry where phone_e164 = '+923001113333'),
  5,
  'the 5 legitimate submissions from the same phone all succeeded'
);
set local role anon;
select throws_ok(
  format('select public.submit_public_enquiry(%L, %L, %L, %L, %L, %L, %L)', 'test-public-enquiry-co', 'Sib 6', '2020-01-06'::date, '1', 'Web Parent', '03001113333', 'ip-c'),
  'RATE_LIMIT_PHONE',
  'AC: a 6th submission from the same phone within 60 minutes is refused'
);
reset role;
select is(
  (select count(*)::int from public.admission_enquiry where phone_e164 = '+923001113333'),
  5,
  'the refused 6th attempt wrote no row'
);
set local role anon;

-- ── IP-based rate limit ──────────────────────────────────────────────

reset role;
insert into public.public_enquiry_attempt (tenant_id, phone_e164, ip_hash)
select :'tenant_id'::uuid, '+9230099900' || lpad(i::text, 2, '0'), 'flood-ip'
  from generate_series(1, 20) i;
set local role anon;
select throws_ok(
  format('select public.submit_public_enquiry(%L, %L, %L, %L, %L, %L, %L)', 'test-public-enquiry-co', 'Flood Child', '2020-01-01'::date, '1', 'Parent', '03009998888', 'flood-ip'),
  'RATE_LIMIT_IP',
  'a 21st submission from the same IP within 60 minutes is refused even with a fresh phone number'
);

-- ── the attempt log has no read API — invisible even to a tenant's own
--    staff, only ever written by submit_public_enquiry() itself ──────

select is((select count(*)::int from public.public_enquiry_attempt), 0, 'the rate-limit log is invisible to anon');

reset role;
set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', '[]'::json)::text,
  true
);
select is((select count(*)::int from public.public_enquiry_attempt), 0, 'the rate-limit log is invisible even to the tenant''s own owner');

select * from finish();
rollback;
