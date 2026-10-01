-- FR-T10: public certificate verification by QR.
--
-- A receiving school or employer scans the QR on a certificate and learns
-- whether it is genuine. This is the one deliberately UNAUTHENTICATED surface in
-- the product, so it is built to leak as little as possible:
--
--   * The QR carries only certificate_issue.verify_token, a random 22-character
--     token, never the student id or GR number (anyone can decode a QR).
--   * The masking happens HERE, in the database, not in the page: a name becomes
--     "A* H" and a GR number "2019-". verify_certificate() returns a finished
--     headline and nothing else. A cancelled certificate returns only the date it
--     was cancelled, with no name or GR, so a replacement issued to someone else
--     is never exposed through the old code.
--   * anon cannot read certificate_issue, the log or the view at all (privileges
--     revoked, not merely RLS-filtered), and has no list to enumerate: the only
--     thing anon can do is execute verify_certificate() with a token it holds.
--     The masked view v_certificate_public_verify is granted to authenticated
--     staff only; granting it to anon would let a caller list every token.
--   * A missing token and a valid one take the same path (one indexed lookup, one
--     log insert) and a miss is a generic 404 "No certificate found for this
--     code". The route adds a response-time floor on top so the difference
--     disappears into it.
--   * More than 60 verifications a minute from one address are answered 429.
--   * Every verification is logged (hashes of the token and the address, user
--     agent, result, campus) and v_certificate_verify_activity groups it by
--     campus, day and serial range: a spike of scans on one serial range is the
--     signature of a forgery ring.
--
-- Tokens do not expire (a printed QR must work for years); "expired or random"
-- in the acceptance criteria is handled as "unknown".

alter table public.certificate_issue
  add column verify_token text not null
    default rtrim(translate(encode(extensions.gen_random_bytes(16), 'base64'), '+/', '-_'), '=');
create unique index uq_cert_verify_token on public.certificate_issue (verify_token);

create table public.certificate_verify_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid references public.tenant(id) on delete cascade,
  campus_id   uuid references public.campus(id) on delete cascade,
  issue_id    uuid references public.certificate_issue(id) on delete set null,
  token_hash  text not null,
  ip_hash     text not null,
  user_agent  text,
  verified_at timestamptz not null default clock_timestamp(),
  result      text not null check (result in ('valid', 'cancelled', 'not_found', 'rate_limited'))
);
create index idx_cert_verify_log_ip on public.certificate_verify_log (ip_hash, verified_at desc);
create index idx_cert_verify_log_campus on public.certificate_verify_log (tenant_id, campus_id, verified_at desc);
create index idx_cert_verify_log_issue on public.certificate_verify_log (issue_id);
alter table public.certificate_verify_log enable row level security;
revoke all on public.certificate_verify_log from anon, authenticated;
grant select on public.certificate_verify_log to authenticated;
create policy cert_verify_log_scope on public.certificate_verify_log for select to authenticated
  using (tenant_id = app.auth_tenant_id()
         and app.auth_role() in ('owner', 'super_admin', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

-- anon never touches the register directly.
revoke all on public.certificate_issue from anon;

-- ── masking, in the database ───────────────────────────────────────────

-- "Ahmed Hassan" -> "A* H": every word but the last keeps its initial and a star, the last keeps only its initial.
create or replace function app.fn_mask_person_name(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  with w as (
    select t.word, t.n from unnest(regexp_split_to_array(btrim(coalesce(p_name, '')), '\s+')) with ordinality as t(word, n) where t.word <> ''
  ), m as (select max(n) as last from w)
  select string_agg(case when w.n = m.last then left(w.word, 1) else left(w.word, 1) || '*' end, ' ' order by w.n)
    from w, m;
$$;
revoke execute on function app.fn_mask_person_name(text) from public, anon;
grant execute on function app.fn_mask_person_name(text) to authenticated;

-- "2019-0311" -> "2019-"; a number with no dash keeps only its first two characters.
create or replace function app.fn_mask_gr(p_gr text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_gr is null then null
              when position('-' in p_gr) > 0 then split_part(p_gr, '-', 1) || '-'
              else left(p_gr, 2) || '*' end;
$$;
revoke execute on function app.fn_mask_gr(text) from public, anon;
grant execute on function app.fn_mask_gr(text) to authenticated;

create or replace function app.fn_certificate_type_label(p_type public.certificate_type)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_type
           when 'transfer' then 'Transfer Certificate'
           when 'character' then 'Character Certificate'
           when 'leaving' then 'School Leaving Certificate'
           else 'Bonafide Certificate' end;
$$;
revoke execute on function app.fn_certificate_type_label(public.certificate_type) from public, anon;
grant execute on function app.fn_certificate_type_label(public.certificate_type) to authenticated;

create or replace view public.v_certificate_public_verify
with (security_invoker = true) as
select ci.verify_token,
       ci.tenant_id,
       ci.campus_id,
       ci.certificate_type,
       app.fn_certificate_type_label(ci.certificate_type) as certificate_label,
       ci.serial_no,
       ci.status,
       (ci.issued_at at time zone 'Asia/Karachi')::date as issued_on,
       (ci.revoked_at at time zone 'Asia/Karachi')::date as cancelled_on,
       case when ci.status = 'issued' then app.fn_mask_person_name(ci.payload_snapshot -> 'values' ->> 'student.name_en') end as masked_name,
       case when ci.status = 'issued' then app.fn_mask_gr(ci.payload_snapshot -> 'values' ->> 'student.gr_number') end as masked_gr
  from public.certificate_issue ci
 where ci.status in ('issued', 'cancelled');
revoke all on public.v_certificate_public_verify from public, anon;
grant select on public.v_certificate_public_verify to authenticated;

-- ── the one entry point ────────────────────────────────────────────────

create or replace function public.verify_certificate(p_token text, p_ip_hash text default null, p_user_agent text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token_hash text := encode(extensions.digest(left(coalesce(p_token, ''), 64), 'sha256'), 'hex');
  v_ip         text := coalesce(nullif(p_ip_hash, ''), 'unknown');
  v_recent     int;
  v_ci         public.certificate_issue%rowtype;
  v_found      boolean := false;
  v_result     text;
  v_out        jsonb;
begin
  -- 60 a minute per address: counted on the log itself, so it holds across every app instance
  select count(*)::int into v_recent from public.certificate_verify_log
   where ip_hash = v_ip and verified_at > clock_timestamp() - interval '1 minute' and result <> 'rate_limited';
  if v_recent >= 60 then
    insert into public.certificate_verify_log (token_hash, ip_hash, user_agent, result)
    select v_token_hash, v_ip, left(p_user_agent, 200), 'rate_limited'
     where not exists (select 1 from public.certificate_verify_log where ip_hash = v_ip and result = 'rate_limited' and verified_at > clock_timestamp() - interval '1 minute');
    return jsonb_build_object('http_status', 429, 'state', 'rate_limited', 'headline', 'Too many requests. Please try again in a minute.');
  end if;

  if p_token is not null and length(p_token) between 16 and 64 then
    select * into v_ci from public.certificate_issue where verify_token = p_token and status in ('issued', 'cancelled');
    v_found := found;
  end if;
  v_result := case when not v_found then 'not_found' when v_ci.status = 'issued' then 'valid' else 'cancelled' end;

  insert into public.certificate_verify_log (tenant_id, campus_id, issue_id, token_hash, ip_hash, user_agent, result)
  values (case when v_found then v_ci.tenant_id end, case when v_found then v_ci.campus_id end, case when v_found then v_ci.id end,
          v_token_hash, v_ip, left(p_user_agent, 200), v_result);

  if v_result = 'valid' then
    v_out := jsonb_build_object(
      'http_status', 200, 'state', 'valid',
      'headline', format('VALID - %s %s issued %s to %s (GR %s)',
                         app.fn_certificate_type_label(v_ci.certificate_type), v_ci.serial_no,
                         to_char((v_ci.issued_at at time zone 'Asia/Karachi')::date, 'DD-Mon-YYYY'),
                         app.fn_mask_person_name(v_ci.payload_snapshot -> 'values' ->> 'student.name_en'),
                         app.fn_mask_gr(v_ci.payload_snapshot -> 'values' ->> 'student.gr_number')));
  elsif v_result = 'cancelled' then
    v_out := jsonb_build_object(
      'http_status', 200, 'state', 'cancelled',
      'headline', format('CANCELLED on %s', to_char((v_ci.revoked_at at time zone 'Asia/Karachi')::date, 'DD-Mon-YYYY')));
  else
    v_out := jsonb_build_object('http_status', 404, 'state', 'not_found', 'headline', 'No certificate found for this code');
  end if;
  return v_out;
end;
$$;
revoke execute on function public.verify_certificate(text, text, text) from public;
grant execute on function public.verify_certificate(text, text, text) to anon, authenticated, service_role;

-- ── the forgery-ring report ────────────────────────────────────────────

create or replace view public.v_certificate_verify_activity
with (security_invoker = true) as
select l.tenant_id, l.campus_id, (l.verified_at at time zone 'Asia/Karachi')::date as day,
       ci.certificate_type, (ci.serial_seq / 50) * 50 as serial_bucket_start,
       count(*) filter (where l.result = 'valid')::int as valid_scans,
       count(*) filter (where l.result = 'cancelled')::int as cancelled_scans,
       count(distinct l.ip_hash)::int as distinct_addresses,
       count(*)::int as total_scans
  from public.certificate_verify_log l
  join public.certificate_issue ci on ci.id = l.issue_id
 group by l.tenant_id, l.campus_id, (l.verified_at at time zone 'Asia/Karachi')::date, ci.certificate_type, (ci.serial_seq / 50) * 50;
revoke all on public.v_certificate_verify_activity from public, anon;
grant select on public.v_certificate_verify_activity to authenticated;
