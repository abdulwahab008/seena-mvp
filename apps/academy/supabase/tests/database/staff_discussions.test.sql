begin;
select plan(9);

select public.provision_tenant('test-discussions', 'Discussions Co', 'owner@discussions.test') as tenant_id \gset
select public.provision_tenant('test-discussions-2', 'Other School', 'owner@discussions2.test') as other_tenant \gset
select gen_random_uuid() as teach_uid \gset
select gen_random_uuid() as lib_uid \gset
select gen_random_uuid() as parent_uid \gset
select gen_random_uuid() as rival_uid \gset
insert into auth.users (id, email, aud, role, encrypted_password) values
  (:'teach_uid', 't@discussions.test', 'authenticated', 'authenticated', 'x'), (:'lib_uid', 'l@discussions.test', 'authenticated', 'authenticated', 'x'),
  (:'parent_uid', 'p@discussions.test', 'authenticated', 'authenticated', 'x'), (:'rival_uid', 'r@discussions2.test', 'authenticated', 'authenticated', 'x');
insert into public.app_user (user_id, tenant_id, app_role, full_name) values
  (:'teach_uid', :'tenant_id', 'subject_teacher', 'Teacher'), (:'lib_uid', :'tenant_id', 'librarian', 'Librarian'),
  (:'parent_uid', :'tenant_id', 'parent', 'Parent'), (:'rival_uid', :'other_tenant', 'owner', 'Rival');

set local role authenticated;
select set_config('request.jwt.claims', json_build_object('sub', :'teach_uid', 'tenant_id', :'tenant_id', 'app_role', 'subject_teacher')::text, true);
select public.post_discussion_thread('Sports day duties', 'Who can cover the relay track?') as thread_id \gset
select is((select author_id from public.discussion_thread where id = :'thread_id'), :'teach_uid'::uuid, 'a teacher starts a thread as its author');
select throws_ok($$ select public.post_discussion_thread('   ', 'x') $$, '22023', 'POST_INVALID', 'a blank title is refused');

select set_config('request.jwt.claims', json_build_object('sub', :'lib_uid', 'tenant_id', :'tenant_id', 'app_role', 'librarian')::text, true);
select lives_ok(format($$ select public.post_discussion_reply(%L, 'I can, after the library closes.') $$, :'thread_id'), 'another staff member replies');
select is((select reply_count from public.discussion_thread where id = :'thread_id'), 1, 'the thread counts its replies');
select is((select count(*)::int from public.discussion_reply where thread_id = :'thread_id'), 1, 'staff read the replies');

select set_config('request.jwt.claims', json_build_object('sub', :'parent_uid', 'tenant_id', :'tenant_id', 'app_role', 'parent')::text, true);
select is((select count(*)::int from public.discussion_thread) + (select count(*)::int from public.discussion_reply), 0, 'a parent sees nothing');
select throws_ok(format($$ select public.post_discussion_reply(%L, 'hello') $$, :'thread_id'), '42501', 'FORBIDDEN', 'and cannot reply');

select set_config('request.jwt.claims', json_build_object('sub', :'rival_uid', 'tenant_id', :'other_tenant', 'app_role', 'owner')::text, true);
select is((select count(*)::int from public.discussion_thread), 0, 'another school sees nothing');
select throws_ok(format($$ select public.post_discussion_reply(%L, 'hello') $$, :'thread_id'), 'P0002', 'THREAD_NOT_FOUND', 'and cannot reply to it');

select * from finish();
rollback;
