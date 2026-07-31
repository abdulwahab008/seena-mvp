-- FR-B02: public self-service web enquiry form.
--
-- Deliberate substitution, documented per this session's established
-- convention of preferring a Postgres-native equivalent over a new
-- deployment target when the security properties are the same:
--   * The FR's own Supabase Objects call for a Supabase Edge Function
--     ("JWT verification disabled... writes with service role only").
--     This codebase has never used Edge Functions — everything is a
--     SECURITY DEFINER Postgres function called through PostgREST, the
--     same pattern get_invitation_preview() already uses for another
--     unauthenticated flow (accept-invite). submit_public_enquiry() is
--     that pattern applied here: granted to anon directly, but it is
--     the ONLY thing anon can do — there is still no anon INSERT policy
--     of any kind on admission_enquiry (the FR's own explicit warning),
--     tenant_id is resolved server-side from the slug and can never be
--     supplied by the caller, and the function does its own rate
--     limiting before it will write anything. A raw REST insert attempt
--     against admission_enquiry as anon is refused by RLS exactly as
--     the FR demands; the function is the only writer.
--   * The rate-limit table is a plain attempt log (tenant_id, phone_e164,
--     ip_hash, created_at) rather than the spec's windowed counter
--     (window_start, hit_count) — a rolling-window count over the log
--     is simpler to reason about and avoids fixed-bucket edge effects
--     (a bucket boundary letting 10 through in 2 minutes), and the
--     log's own two indexes are exactly the spec's own
--     idx_rate_limit_window / idx_rate_limit_ip in spirit.
--   * No age-override path: create_enquiry() lets a staff member note a
--     reason and admit an underage Nursery enquiry anyway; an anonymous
--     public submission has no one to exercise that judgment, so it is
--     a hard rejection here instead.
--   * Realtime: admission_enquiry is added to the supabase_realtime
--     publication. The existing SELECT RLS policy already scopes what
--     each subscriber receives by tenant + campus — Realtime enforces
--     the same RLS as any other read, so "filtered by campus_id" falls
--     out of that for free rather than needing a bespoke filter.

create table public.public_enquiry_attempt (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  phone_e164 text not null,
  ip_hash    text not null,
  created_at timestamptz not null default clock_timestamp()
);

create index idx_enquiry_attempt_phone_window on public.public_enquiry_attempt (phone_e164, created_at);
create index idx_enquiry_attempt_ip_window on public.public_enquiry_attempt (ip_hash, created_at);

alter table public.public_enquiry_attempt enable row level security;
-- No policies at all, deliberately — this is an internal bookkeeping
-- table with no read API; even a tenant's own staff have no need to
-- browse it, so it is invisible to every role including authenticated.

create or replace function public.submit_public_enquiry(
  p_tenant_slug     text,
  p_child_name      text,
  p_dob             date,
  p_class_code      text,
  p_parent_name     text,
  p_phone           text,
  p_ip_hash         text,
  p_child_name_ur   text default null,
  p_whatsapp_opt_in boolean default false,
  p_campus_code     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id     uuid;
  v_campus_id     uuid;
  v_session_id    uuid;
  v_phone         text;
  v_class_id      uuid;
  v_class_ordinal smallint;
  v_ref_date      date;
  v_age_months    int;
  v_phone_count   int;
  v_ip_count      int;
  v_id            uuid;
  v_enquiry_no    text;
begin
  select id into v_tenant_id from public.tenant where lower(slug) = lower(p_tenant_slug) and status = 'active';
  if v_tenant_id is null then
    raise exception 'TENANT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_campus_code is not null then
    select id into v_campus_id from public.campus where tenant_id = v_tenant_id and code = p_campus_code and status = 'active';
  else
    select id into v_campus_id from public.campus where tenant_id = v_tenant_id and status = 'active' order by code limit 1;
  end if;
  if v_campus_id is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  select id into v_session_id from public.academic_session where campus_id = v_campus_id and is_current = true;
  if v_session_id is null then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  v_phone := public.normalize_pk_phone(p_phone);
  if v_phone is null then
    raise exception 'PHONE_INVALID' using errcode = '22023';
  end if;

  -- AC: a 6th submission from the same phone within 60 minutes is
  -- refused with no row written under any tenant.
  select count(*) into v_phone_count
    from public.public_enquiry_attempt
   where phone_e164 = v_phone and created_at > clock_timestamp() - interval '60 minutes';
  if v_phone_count >= 5 then
    raise exception 'RATE_LIMIT_PHONE' using errcode = '55006';
  end if;

  select count(*) into v_ip_count
    from public.public_enquiry_attempt
   where ip_hash = p_ip_hash and created_at > clock_timestamp() - interval '60 minutes';
  if v_ip_count >= 20 then
    raise exception 'RATE_LIMIT_IP' using errcode = '55006';
  end if;

  select id, ordinal into v_class_id, v_class_ordinal
    from public.class_level where tenant_id = v_tenant_id and code = p_class_code and is_active = true;
  if v_class_id is null then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;

  if v_class_ordinal = 0 then
    select starts_on into v_ref_date from public.academic_session where id = v_session_id;
    v_ref_date := make_date(extract(year from v_ref_date)::int, 4, 1);
    v_age_months := extract(year from age(v_ref_date, p_dob))::int * 12 + extract(month from age(v_ref_date, p_dob))::int;
    if v_age_months < 30 then
      raise exception 'AGE_BELOW_MINIMUM' using errcode = '23514';
    end if;
  end if;

  insert into public.admission_enquiry (
    tenant_id, campus_id, session_id, child_name, child_name_ur, dob, class_applied_id,
    parent_name, phone_e164, whatsapp_opt_in, source
  ) values (
    v_tenant_id, v_campus_id, v_session_id, p_child_name, p_child_name_ur, p_dob, v_class_id,
    p_parent_name, v_phone, p_whatsapp_opt_in, 'web'
  )
  returning id, enquiry_no into v_id, v_enquiry_no;

  insert into public.public_enquiry_attempt (tenant_id, phone_e164, ip_hash) values (v_tenant_id, v_phone, p_ip_hash);

  return jsonb_build_object('enquiry_id', v_id, 'enquiry_no', v_enquiry_no);
end;
$$;

revoke execute on function public.submit_public_enquiry(text, text, date, text, text, text, text, text, boolean, text) from public;
grant execute on function public.submit_public_enquiry(text, text, date, text, text, text, text, text, boolean, text) to anon, authenticated;

-- The public form needs a class list to offer — class_level's own RLS
-- requires a tenant JWT, so an anonymous visitor can't read it directly.
-- This is the read-only counterpart to submit_public_enquiry(): tenant
-- resolved from the slug, nothing else exposed.
create or replace function public.fn_public_school_info(p_tenant_slug text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid;
  v_name      text;
  v_classes   jsonb;
begin
  select id, name into v_tenant_id, v_name from public.tenant where lower(slug) = lower(p_tenant_slug) and status = 'active';
  if v_tenant_id is null then
    raise exception 'TENANT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'name_en', name_en, 'name_ur', name_ur) order by ordinal), '[]'::jsonb)
    into v_classes
    from public.class_level where tenant_id = v_tenant_id and is_active = true;

  return jsonb_build_object('tenant_name', v_name, 'class_levels', v_classes);
end;
$$;

revoke execute on function public.fn_public_school_info(text) from public;
grant execute on function public.fn_public_school_info(text) to anon, authenticated;

alter publication supabase_realtime add table public.admission_enquiry;
