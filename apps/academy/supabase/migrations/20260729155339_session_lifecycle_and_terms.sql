-- FR-A04 (academic session lifecycle) and FR-A05 (term definition).
--
-- Reconciliation note: FR-A04's acceptance criteria describe session
-- statuses as planning/current/closing/closed, but the foundation
-- migration already shipped and tested academic_session.status as
-- planned/active/closed/archived (matching data-model.md) with a
-- separate `is_current` boolean enforced by partial unique indexes and
-- consumed by the JWT hook. Reusing that rather than redefining it: this
-- migration treats status='active' as "current" and transitions the
-- previous current session straight to 'closed' (skipping a distinct
-- "closing" grace state — that state has no consumer until FR-A06's
-- rollover engine exists to give it meaning; add it then, not now).

-- ── overlap guard (applies to every insert/update, not just set_current) ──

create or replace function app.tg_session_no_excessive_overlap()
returns trigger
language plpgsql
as $$
declare
  v_overlap_days int;
  v_conflict record;
begin
  select s.id, s.name,
         greatest(0, least(s.ends_on, new.ends_on) - greatest(s.starts_on, new.starts_on) + 1) as overlap_days
    into v_conflict
    from public.academic_session s
   where s.tenant_id = new.tenant_id
     and s.campus_id is not distinct from new.campus_id
     and s.id <> new.id
     and s.starts_on <= new.ends_on
     and s.ends_on >= new.starts_on
   order by overlap_days desc
   limit 1;

  if found and v_conflict.overlap_days > 90 then
    raise exception 'SESSION_OVERLAP'
      using errcode = '23P01',
            detail = format('%s days overlap with session "%s"', v_conflict.overlap_days, v_conflict.name);
  end if;

  return new;
end;
$$;

create trigger academic_session_no_excessive_overlap
  before insert or update of starts_on, ends_on, campus_id on public.academic_session
  for each row execute function app.tg_session_no_excessive_overlap();

-- ── create_academic_session (FR-A04) ─────────────────────────────────────
-- No direct-INSERT RLS policy on academic_session on purpose: the overlap
-- trigger validates *dates*, but authorization (who, which tenant/campus)
-- needs to live somewhere, and every other controlled write in this schema
-- goes through a SECURITY DEFINER function rather than an INSERT policy —
-- keeping that one pattern rather than splitting authorization across two
-- mechanisms.

create or replace function public.create_academic_session(
  p_campus_id uuid,
  p_name      text,
  p_starts_on date,
  p_ends_on   date
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_session_id uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if p_campus_id is not null and not exists (
    select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.academic_session (tenant_id, campus_id, name, starts_on, ends_on)
  values (v_tenant_id, p_campus_id, p_name, p_starts_on, p_ends_on)
  returning id into v_session_id;

  return v_session_id;
end;
$$;

revoke execute on function public.create_academic_session(uuid, text, date, date) from public, anon;
grant execute on function public.create_academic_session(uuid, text, date, date) to authenticated;

-- ── set_current_session (FR-A04) ─────────────────────────────────────────

create or replace function public.set_current_session(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_campus_id uuid;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select campus_id into v_campus_id
    from public.academic_session
   where id = p_session_id and tenant_id = v_tenant_id;
  if v_campus_id is null then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Partial unique indexes (academic_session_current_per_campus_uniq /
  -- _tenant_wide_uniq, from the foundation migration) make this atomic:
  -- if a concurrent request races to make a DIFFERENT session current for
  -- the same campus, one of the two INSERTs/UPDATEs below will violate the
  -- index and abort — never two rows left is_current in the same campus.
  update public.academic_session
     set is_current = false, status = 'closed'
   where tenant_id = v_tenant_id
     and campus_id is not distinct from v_campus_id
     and is_current
     and id <> p_session_id;

  update public.academic_session
     set is_current = true, status = 'active'
   where id = p_session_id;
end;
$$;

revoke execute on function public.set_current_session(uuid) from public, anon;
grant execute on function public.set_current_session(uuid) to authenticated;

-- ── academic_term (FR-A05) ────────────────────────────────────────────────

create table public.academic_term (
  id         uuid primary key default gen_random_uuid(),
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  session_id uuid not null references public.academic_session(id) on delete cascade,
  name       text not null,
  name_ur    text,
  starts_on  date not null,
  ends_on    date not null,
  weightage  numeric(5,2) not null check (weightage > 0 and weightage <= 100),
  sequence   smallint not null,
  is_locked  boolean not null default false,
  created_at timestamptz not null default now(),
  constraint academic_term_dates_chk check (ends_on > starts_on)
);

create index academic_term_session_idx on public.academic_term (session_id);
create unique index academic_term_sequence_uniq on public.academic_term (session_id, sequence);

alter table public.academic_term enable row level security;

create policy academic_term_tenant_scope on public.academic_term
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());

-- Terms are defined as a whole set per session (1-4 rows whose weightage
-- must sum to exactly 100), not incrementally — an incremental per-row
-- trigger can't validate a sum that's only meaningful once the full set
-- exists. p_terms: jsonb array of {name, name_ur?, starts_on, ends_on, weightage}.
create or replace function public.set_academic_terms(p_session_id uuid, p_terms jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_count     int;
  -- Deliberately unconstrained scale: a numeric(6,2) variable would render
  -- a whole-number sum as "95.00" via RAISE's %-formatting, breaking the
  -- exact TERM_WEIGHTAGE_SUM=95 message the acceptance criteria specify.
  v_sum       numeric;
  v_locked    int;
begin
  if v_tenant_id is null or app.auth_role() not in ('owner', 'principal', 'exam_controller', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = v_tenant_id) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;

  select count(*) into v_locked from public.academic_term where session_id = p_session_id and is_locked;
  if v_locked > 0 then
    raise exception 'TERM_LOCKED' using errcode = '55000';
  end if;

  select count(*), coalesce(sum((t->>'weightage')::numeric), 0)
    into v_count, v_sum
    from jsonb_array_elements(p_terms) as t;

  if v_count < 1 or v_count > 4 then
    raise exception 'TERM_COUNT_INVALID: % (must be 1-4)', v_count using errcode = '22023';
  end if;
  if v_sum <> 100 then
    raise exception 'TERM_WEIGHTAGE_SUM=%', v_sum using errcode = '22023';
  end if;

  delete from public.academic_term where session_id = p_session_id;

  insert into public.academic_term (tenant_id, session_id, name, name_ur, starts_on, ends_on, weightage, sequence)
  select v_tenant_id,
         p_session_id,
         t->>'name',
         t->>'name_ur',
         (t->>'starts_on')::date,
         (t->>'ends_on')::date,
         (t->>'weightage')::numeric,
         (row_number() over ())::smallint
    from jsonb_array_elements(p_terms) as t;
end;
$$;

revoke execute on function public.set_academic_terms(uuid, jsonb) from public, anon;
grant execute on function public.set_academic_terms(uuid, jsonb) to authenticated;
