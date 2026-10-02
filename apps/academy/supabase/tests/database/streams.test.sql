-- pgTAP tests for FR-E05: elective stream definition, section<->stream
-- assignment, and the applies_from_ordinal gate.
begin;
select plan(7);

select public.provision_tenant('test-stream-co', 'Stream Co', 'owner@streamco.test');
select id as tenant_id from public.tenant where slug = 'test-stream-co' \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' \gset
select id as session_id from public.academic_session where tenant_id = :'tenant_id' \gset
select id as class8_id from public.class_level where tenant_id = :'tenant_id' and code = '8' \gset
select id as class9_id from public.class_level where tenant_id = :'tenant_id' and code = '9' \gset

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object('tenant_id', :'tenant_id', 'app_role', 'owner', 'campus_ids', json_build_array(:'campus_id'))::text,
  true
);

-- Pre-Medical applies from class 9 (ordinal 10).
select public.create_stream('PREMED', 'Pre-Medical', 'پری میڈیکل', 'FBISE', 10::smallint) as premed_id \gset

select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class9_id', p_name => 'A', p_capacity => 40) as section9a_id \gset
select public.create_section(p_campus_id => :'campus_id', p_session_id => :'session_id', p_class_level_id => :'class8_id', p_name => 'A', p_capacity => 40) as section8a_id \gset

select lives_ok(
  format('select public.set_section_stream(%L, %L)', :'section9a_id', :'premed_id'),
  'assigning Pre-Medical to a class 9 section succeeds (ordinal 10 >= applies_from 10)'
);
select is(
  (select stream_id from public.class_section where id = :'section9a_id'),
  :'premed_id',
  'the section now carries the assigned stream'
);

select throws_ok(
  format('select public.set_section_stream(%L, %L)', :'section8a_id', :'premed_id'),
  'STREAM_NOT_OFFERED_FOR_CLASS',
  'assigning Pre-Medical to a class 8 section is rejected (ordinal 9 < applies_from 10)'
);

-- A section carries at most one stream by construction: reassigning just
-- overwrites the single stream_id column, never adds a second.
select public.create_stream('PREENG', 'Pre-Engineering', 'پری انجینئرنگ', 'FBISE', 10::smallint) as preeng_id \gset
select public.set_section_stream(:'section9a_id', :'preeng_id');
select is(
  (select stream_id from public.class_section where id = :'section9a_id'),
  :'preeng_id',
  'reassigning a section''s stream replaces it — a section only ever carries one'
);

-- Deletion is blocked while a section references the stream.
select throws_ok(
  format('select public.delete_stream(%L)', :'preeng_id'),
  'STREAM_IN_USE',
  'deleting a stream that a section still references is rejected'
);

select public.set_section_stream(:'section9a_id', null);
select lives_ok(
  format('select public.delete_stream(%L)', :'preeng_id'),
  'once no section references it, the stream can be deleted'
);
select is(
  (select count(*)::int from public.stream where id = :'preeng_id'),
  0,
  'the deleted stream is actually gone'
);

select * from finish();
rollback;
