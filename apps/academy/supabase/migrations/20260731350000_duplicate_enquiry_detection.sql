-- FR-B03: detect and merge duplicate enquiries.
--
-- Design note on "before the save completes" (the AC's own words): there
-- is no enquiry_id to merge or dismiss against until a row actually
-- exists, and AC3's "both rows persist" after a "Not a duplicate" choice
-- confirms the second row IS created either way. So the real flow is:
-- create_enquiry() runs as it always has (unchanged, no signature
-- ripple), and fn_find_duplicate_enquiries() is called immediately
-- afterward — excluding the row just created — as part of the SAME
-- submit action, before the caller is told the enquiry is fully
-- processed. Merge/Dismiss then operate on two real, existing ids.
--
-- pg_trgm is already enabled (students.sql). Fuzzy name matching only
-- fires alongside an exact DOB match — name-similarity alone across a
-- whole tenant would surface far too many false positives ("Ali" is not
-- a rare name).
--
-- "excluded from all funnel counts" (AC2): no funnel-count view exists
-- yet in this codebase to update — status='merged' is a distinct value
-- from 'open'/'converted'/'lost', so any current or future count-by-
-- status query already excludes it by construction.

alter table public.admission_enquiry add column merged_into_id uuid references public.admission_enquiry(id);

create table public.enquiry_duplicate_dismissed (
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  enquiry_a    uuid not null references public.admission_enquiry(id) on delete cascade,
  enquiry_b    uuid not null references public.admission_enquiry(id) on delete cascade,
  dismissed_by uuid references public.app_user(user_id),
  dismissed_at timestamptz not null default clock_timestamp(),
  constraint chk_dismissed_pair_ordered check (enquiry_a < enquiry_b),
  primary key (enquiry_a, enquiry_b)
);

-- Tenant-wide on purpose, not campus-scoped: AC4's cross-campus scenario
-- requires an Admissions Officer (who may be scoped to one campus) to be
-- able to find a candidate sitting on a DIFFERENT campus in the first
-- place, in order to be routed to a Principal for approval — a
-- campus_ids filter here would hide the very duplicate this FR exists to
-- catch.
create or replace function public.fn_find_duplicate_enquiries(
  p_phone text default null, p_cnic text default null, p_name text default null, p_dob date default null,
  p_exclude_enquiry_id uuid default null
)
returns table (
  id uuid, enquiry_no text, child_name text, phone_e164 text, campus_id uuid,
  status public.enquiry_status, last_followup_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_phone     text;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  v_phone := case when p_phone is not null and btrim(p_phone) <> '' then public.normalize_pk_phone(p_phone) else null end;

  return query
    select
      e.id, e.enquiry_no, e.child_name, e.phone_e164, e.campus_id, e.status,
      (select max(coalesce(f.completed_at, f.due_at)) from public.admission_followup f where f.enquiry_id = e.id)
    from public.admission_enquiry e
   where e.tenant_id = v_tenant_id
     and e.status = 'open'
     and (p_exclude_enquiry_id is null or e.id <> p_exclude_enquiry_id)
     and (
       (v_phone is not null and e.phone_e164 = v_phone)
       or (p_cnic is not null and btrim(p_cnic) <> '' and e.parent_cnic = p_cnic)
       or (p_name is not null and p_dob is not null and e.dob = p_dob and public.similarity(e.child_name, p_name) > 0.4)
     )
     and (
       p_exclude_enquiry_id is null or not exists (
         select 1 from public.enquiry_duplicate_dismissed d
          where d.tenant_id = v_tenant_id
            and d.enquiry_a = least(p_exclude_enquiry_id, e.id)
            and d.enquiry_b = greatest(p_exclude_enquiry_id, e.id)
       )
     );
end;
$$;

revoke execute on function public.fn_find_duplicate_enquiries(text, text, text, date, uuid) from public, anon;
grant execute on function public.fn_find_duplicate_enquiries(text, text, text, date, uuid) to authenticated;

-- AC: follow-ups re-parent to the survivor (documents would too, but no
-- document-upload table exists yet for enquiries — nothing else
-- currently references an enquiry_id to re-parent). The loser's status
-- becomes 'merged', never deleted, so first-touch source attribution
-- survives for the marketing-spend reporting the FR's own Notes call out.
create or replace function public.fn_merge_enquiry(p_survivor_id uuid, p_loser_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_survivor  public.admission_enquiry%rowtype;
  v_loser     public.admission_enquiry%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_survivor_id = p_loser_id then
    raise exception 'SAME_ENQUIRY' using errcode = '22023';
  end if;

  select * into v_survivor from public.admission_enquiry where id = p_survivor_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SURVIVOR_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_loser from public.admission_enquiry where id = p_loser_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'LOSER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_survivor.status <> 'open' or v_loser.status <> 'open' then
    raise exception 'ENQUIRY_NOT_OPEN' using errcode = '55000';
  end if;

  -- AC: a cross-campus merge is refused for an Admissions Officer and
  -- needs a Principal (or above) in the loop — seat counts and officer
  -- commissions are campus-level.
  if v_survivor.campus_id <> v_loser.campus_id and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'CROSS_CAMPUS_MERGE_REQUIRES_PRINCIPAL' using errcode = '42501';
  end if;

  update public.admission_followup set campus_id = v_survivor.campus_id, enquiry_id = p_survivor_id where enquiry_id = p_loser_id;
  update public.admission_enquiry set status = 'merged', merged_into_id = p_survivor_id where id = p_loser_id;
end;
$$;

revoke execute on function public.fn_merge_enquiry(uuid, uuid) from public, anon;
grant execute on function public.fn_merge_enquiry(uuid, uuid) to authenticated;

create or replace function public.fn_dismiss_duplicate_enquiry(p_enquiry_a uuid, p_enquiry_b uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_enquiry_a = p_enquiry_b then
    raise exception 'SAME_ENQUIRY' using errcode = '22023';
  end if;
  if not exists (select 1 from public.admission_enquiry where id = p_enquiry_a and tenant_id = v_tenant_id) then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.admission_enquiry where id = p_enquiry_b and tenant_id = v_tenant_id) then
    raise exception 'ENQUIRY_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.enquiry_duplicate_dismissed (tenant_id, enquiry_a, enquiry_b, dismissed_by)
  values (v_tenant_id, least(p_enquiry_a, p_enquiry_b), greatest(p_enquiry_a, p_enquiry_b), auth.uid())
  on conflict (enquiry_a, enquiry_b) do nothing;
end;
$$;

revoke execute on function public.fn_dismiss_duplicate_enquiry(uuid, uuid) from public, anon;
grant execute on function public.fn_dismiss_duplicate_enquiry(uuid, uuid) to authenticated;

create index idx_enquiry_name_trgm on public.admission_enquiry using gin (child_name gin_trgm_ops);
create index idx_enquiry_cnic on public.admission_enquiry (tenant_id, parent_cnic);

alter table public.enquiry_duplicate_dismissed enable row level security;

create policy dismissed_duplicate_tenant_read on public.enquiry_duplicate_dismissed
  for select to authenticated
  using (tenant_id = app.auth_tenant_id());
