-- Staff discussion board: threads and replies, visible to every staff member
-- of the school and never to parents or students.

create table public.discussion_thread (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  title            text not null check (length(btrim(title)) between 1 and 200),
  body             text not null check (length(btrim(body)) between 1 and 5000),
  author_id        uuid not null default auth.uid() references auth.users(id),
  reply_count      int not null default 0,
  last_activity_at timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
create index idx_discussion_thread_tenant on public.discussion_thread (tenant_id, last_activity_at desc);

create table public.discussion_reply (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  thread_id  uuid not null references public.discussion_thread(id) on delete cascade,
  body       text not null check (length(btrim(body)) between 1 and 5000),
  author_id  uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);
create index idx_discussion_reply_thread on public.discussion_reply (thread_id, created_at);
create index idx_discussion_reply_tenant on public.discussion_reply (tenant_id);

alter table public.discussion_thread enable row level security;
alter table public.discussion_reply enable row level security;
create policy discussion_thread_read on public.discussion_thread for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none'));
create policy discussion_reply_read on public.discussion_reply for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() not in ('parent', 'student', 'none'));
select app.fn_block_portal_roles('public.discussion_thread');
select app.fn_block_portal_roles('public.discussion_reply');

create or replace function public.post_discussion_thread(p_title text, p_body text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_staff();
  if length(btrim(coalesce(p_title, ''))) not between 1 and 200 or length(btrim(coalesce(p_body, ''))) not between 1 and 5000 then
    raise exception 'POST_INVALID' using errcode = '22023';
  end if;
  insert into public.discussion_thread (tenant_id, title, body)
  values (app.auth_tenant_id(), btrim(p_title), btrim(p_body))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.post_discussion_thread(text, text) from public, anon;
grant execute on function public.post_discussion_thread(text, text) to authenticated;

create or replace function public.post_discussion_reply(p_thread_id uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_staff();
  if length(btrim(coalesce(p_body, ''))) not between 1 and 5000 then
    raise exception 'POST_INVALID' using errcode = '22023';
  end if;
  update public.discussion_thread
     set reply_count = reply_count + 1, last_activity_at = now()
   where id = p_thread_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'THREAD_NOT_FOUND' using errcode = 'P0002';
  end if;
  insert into public.discussion_reply (tenant_id, thread_id, body)
  values (app.auth_tenant_id(), p_thread_id, btrim(p_body))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.post_discussion_reply(uuid, text) from public, anon;
grant execute on function public.post_discussion_reply(uuid, text) to authenticated;
