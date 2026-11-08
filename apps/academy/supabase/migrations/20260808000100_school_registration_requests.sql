-- Sign-in journey: public sign-up is gone. Nobody needs an account that
-- belongs to no school: owners get theirs from the platform console, staff
-- and parents by invitation, students by GR number. A school that wants
-- Seena fills in a registration request instead, which lands in the
-- platform console.
--
-- The school-branded sign-in link (/login?school=code) reads the school's
-- name through the existing public fn_public_school_info.

create table public.school_registration_request (
  id             uuid primary key default gen_random_uuid(),
  school_name    text not null check (length(btrim(school_name)) between 2 and 150),
  contact_name   text not null check (length(btrim(contact_name)) between 2 and 120),
  phone          text not null check (phone ~ '^\+?[0-9 -]{10,16}$'),
  email          text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  city           text check (city is null or length(city) <= 80),
  students       int check (students is null or students between 1 and 100000),
  message        text check (message is null or length(message) <= 1000),
  status         text not null default 'new' check (status in ('new', 'contacted', 'onboarded', 'declined')),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index idx_school_registration_request_status on public.school_registration_request (status, created_at desc);
create index idx_school_registration_request_phone on public.school_registration_request (phone, created_at desc);

alter table public.school_registration_request enable row level security;
create policy school_registration_request_platform_read on public.school_registration_request for select to authenticated
  using (app.is_platform_admin());
revoke all on public.school_registration_request from anon;
select app.fn_block_portal_roles('public.school_registration_request');

-- Anyone may ask; the same phone at most three times a day, so the form
-- cannot be used to flood the console.
create or replace function public.submit_school_registration(p_school_name text, p_contact_name text, p_phone text,
  p_email text default null, p_city text default null, p_students int default null, p_message text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[ -]', '', 'g');
  v_id    uuid;
begin
  if (select count(*) from public.school_registration_request where phone = v_phone and created_at > now() - interval '1 day') >= 3 then
    raise exception 'TOO_MANY_REQUESTS' using errcode = '54000';
  end if;
  insert into public.school_registration_request (school_name, contact_name, phone, email, city, students, message)
  values (btrim(p_school_name), btrim(p_contact_name), v_phone, nullif(lower(btrim(coalesce(p_email, ''))), ''),
          nullif(btrim(coalesce(p_city, '')), ''), p_students, nullif(btrim(coalesce(p_message, '')), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.submit_school_registration(text, text, text, text, text, int, text) from public;
grant execute on function public.submit_school_registration(text, text, text, text, text, int, text) to anon, authenticated;

create or replace function public.platform_set_registration_status(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_platform_admin();
  if p_status not in ('new', 'contacted', 'onboarded', 'declined') then
    raise exception 'STATUS_INVALID' using errcode = '22023';
  end if;
  update public.school_registration_request set status = p_status, updated_at = now() where id = p_id;
  if not found then
    raise exception 'REQUEST_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.platform_set_registration_status(uuid, text) from public, anon;
grant execute on function public.platform_set_registration_status(uuid, text) to authenticated;
