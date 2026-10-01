-- FR-D14: staff appraisal cycle and scoring.
--
-- A cycle (per academic session) carries a weighted competency template. It can
-- only be published when the weights sum to exactly 100; publishing freezes the
-- template (the competencies can no longer be edited, and every appraisal gets
-- its own copy in template_snapshot, so a later edit for the NEXT cycle can never
-- change a signed score) and opens one appraisal per ELIGIBLE staff member:
-- active staff whose service at the cycle's closing date is at least
-- min_service_days. Anyone below that is not in the cycle and therefore not in
-- its aggregate report.
--
--   in_progress -> (rater scores every competency, 1 to 5) -> release ->
--   released -> appraisee acknowledges -> final
--            \-> appraisee disputes (up to 2000 characters, visible to the Owner)
--                -> awaiting_acknowledgement -> Owner/HR finalise_appraisal -> final
--
-- score = sum(weight_pct x rating / 5), so six competencies weighted 25/20/20/15/10/10
-- all rated 4 give 80.00 of 100. It is computed ONCE, at release, from the
-- snapshot weights.
--
-- Visibility flips on the explicit release step, not on the row existing: until
-- release the appraisee's table query returns no row (RLS) and get_my_appraisal()
-- reports only status 'in_progress' with no scores. The rater and the people who
-- run the process (HR, Owner) can read; nobody else can. All writes go through
-- SECURITY DEFINER functions.

create type public.appraisal_cycle_status as enum ('draft', 'published', 'closed');
create type public.appraisal_status as enum ('in_progress', 'released', 'awaiting_acknowledgement', 'final');

create table public.appraisal_cycle (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  session_id       uuid not null references public.academic_session(id) on delete cascade,
  name             text not null check (char_length(btrim(name)) between 1 and 120),
  opens_on         date not null,
  closes_on        date not null,
  min_service_days smallint not null default 90 check (min_service_days >= 0),
  status           public.appraisal_cycle_status not null default 'draft',
  published_at     timestamptz,
  created_by       uuid references public.app_user(user_id),
  created_at       timestamptz not null default now(),
  constraint chk_cycle_dates check (closes_on >= opens_on)
);
create index idx_appraisal_cycle_tenant on public.appraisal_cycle (tenant_id, status);
create index idx_appraisal_cycle_session on public.appraisal_cycle (session_id);

create table public.appraisal_competency (
  id         uuid primary key default gen_random_uuid(),
  cycle_id   uuid not null references public.appraisal_cycle(id) on delete cascade,
  tenant_id  uuid not null references public.tenant(id) on delete cascade,
  name       text not null check (char_length(btrim(name)) between 1 and 120),
  weight_pct numeric(5, 2) not null check (weight_pct > 0 and weight_pct <= 100),
  sort_order smallint not null default 0
);
create index idx_appraisal_competency_cycle on public.appraisal_competency (cycle_id, sort_order);
create index idx_appraisal_competency_tenant on public.appraisal_competency (tenant_id);

create table public.appraisal (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  cycle_id          uuid not null references public.appraisal_cycle(id) on delete cascade,
  staff_id          uuid not null references public.staff(id) on delete cascade,
  rater_id          uuid not null references public.app_user(user_id),
  status            public.appraisal_status not null default 'in_progress',
  total_score       numeric(5, 2),
  template_snapshot jsonb not null,
  released_at       timestamptz,
  acknowledged_at   timestamptz,
  appraisee_comment text check (appraisee_comment is null or char_length(appraisee_comment) <= 2000),
  finalised_by      uuid references public.app_user(user_id),
  created_at        timestamptz not null default now(),
  constraint uq_appraisal_cycle_staff unique (cycle_id, staff_id),
  constraint chk_appraisal_released check ((status = 'in_progress') = (released_at is null))
);
create index idx_appraisal_cycle_staff on public.appraisal (cycle_id, staff_id);
create index idx_appraisal_rater on public.appraisal (rater_id, status);
create index idx_appraisal_tenant on public.appraisal (tenant_id);
create index idx_appraisal_campus on public.appraisal (campus_id);

create table public.appraisal_score (
  appraisal_id  uuid not null references public.appraisal(id) on delete cascade,
  competency_id uuid not null,
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  rating        smallint not null check (rating between 1 and 5),
  primary key (appraisal_id, competency_id)
);
create index idx_appraisal_score_tenant on public.appraisal_score (tenant_id);

create trigger appraisal_cycle_audit after insert or update or delete on public.appraisal_cycle for each row execute function app.tg_audit_row();
create trigger appraisal_competency_audit after insert or update or delete on public.appraisal_competency for each row execute function app.tg_audit_row();
create trigger appraisal_audit after insert or update or delete on public.appraisal for each row execute function app.tg_audit_row();
create trigger appraisal_score_audit after insert or update or delete on public.appraisal_score for each row execute function app.tg_audit_row();
-- the audit trail must not show what the appraisee is not yet allowed to see
insert into public.audit_redacted_column (table_name, column_name) values
  ('appraisal_score', 'rating'), ('appraisal', 'total_score'), ('appraisal', 'appraisee_comment')
on conflict do nothing;

-- ── the weights rule ──────────────────────────────────────────────────────

-- Once a cycle is published its template is frozen.
create or replace function app.tg_appraisal_competency_frozen()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_status public.appraisal_cycle_status;
begin
  select status into v_status from public.appraisal_cycle where id = coalesce(new.cycle_id, old.cycle_id);
  if v_status is not null and v_status <> 'draft' then
    raise exception 'CYCLE_TEMPLATE_FROZEN' using errcode = '55000';
  end if;
  return coalesce(new, old);
end;
$$;
create trigger trg_appraisal_competency_frozen before insert or update or delete on public.appraisal_competency
  for each row execute function app.tg_appraisal_competency_frozen();

-- trg_weights_sum_100: deferred to commit, so a draft template can be built
-- up line by line, but no published cycle can ever end a transaction without
-- weights summing to 100.
create or replace function app.tg_appraisal_weights_sum_100()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_cycle  uuid := coalesce(new.cycle_id, old.cycle_id);
  v_status public.appraisal_cycle_status;
  v_sum    numeric;
begin
  select status into v_status from public.appraisal_cycle where id = v_cycle;
  if v_status is null or v_status = 'draft' then
    return null;
  end if;
  select coalesce(sum(weight_pct), 0) into v_sum from public.appraisal_competency where cycle_id = v_cycle;
  if v_sum <> 100 then
    raise exception 'WEIGHTS_NOT_100: weights sum to %', v_sum using errcode = '23514';
  end if;
  return null;
end;
$$;
create constraint trigger trg_weights_sum_100 after insert or update or delete on public.appraisal_competency
  deferrable initially deferred for each row execute function app.tg_appraisal_weights_sum_100();

-- ── RLS ───────────────────────────────────────────────────────────────────

alter table public.appraisal_cycle enable row level security;
alter table public.appraisal_competency enable row level security;
alter table public.appraisal enable row level security;
alter table public.appraisal_score enable row level security;
revoke insert, update, delete on public.appraisal_cycle, public.appraisal_competency, public.appraisal, public.appraisal_score from authenticated, anon;

create policy appraisal_cycle_read on public.appraisal_cycle for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal'));
create policy appraisal_competency_read on public.appraisal_competency for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'principal'));

-- the rater reads (and, through the functions, writes) the appraisals they were assigned
create policy appraisal_rater_write on public.appraisal for select to authenticated
  using (tenant_id = app.auth_tenant_id() and rater_id = (select auth.uid()));
-- the appraisee sees theirs only after it is released
create policy appraisal_appraisee_read_after_release on public.appraisal for select to authenticated
  using (tenant_id = app.auth_tenant_id() and status <> 'in_progress'
         and exists (select 1 from public.staff s where s.id = staff_id and s.user_id = (select auth.uid())));
create policy appraisal_owner_read_all on public.appraisal for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('super_admin', 'owner', 'hr_manager'));

create policy appraisal_score_read on public.appraisal_score for select to authenticated
  using (tenant_id = app.auth_tenant_id() and exists (select 1 from public.appraisal a where a.id = appraisal_id));

-- ── the cycle ─────────────────────────────────────────────────────────────

create or replace function public.create_appraisal_cycle(p_session_id uuid, p_name text, p_opens_on date, p_closes_on date, p_min_service_days smallint default 90)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.academic_session where id = p_session_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_closes_on < p_opens_on then
    raise exception 'DATES_INVALID' using errcode = '22023';
  end if;
  insert into public.appraisal_cycle (tenant_id, session_id, name, opens_on, closes_on, min_service_days, created_by)
  values (app.auth_tenant_id(), p_session_id, btrim(p_name), p_opens_on, p_closes_on, p_min_service_days, (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.create_appraisal_cycle(uuid, text, date, date, smallint) from public, anon;
grant execute on function public.create_appraisal_cycle(uuid, text, date, date, smallint) to authenticated;

-- Replaces the template of a DRAFT cycle: [{"name": "...", "weight_pct": 25}, ...]
create or replace function public.set_cycle_competencies(p_cycle_id uuid, p_competencies jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle public.appraisal_cycle%rowtype;
  c       jsonb;
  i       smallint := 0;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_cycle from public.appraisal_cycle where id = p_cycle_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'CYCLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_cycle.status <> 'draft' then
    raise exception 'CYCLE_TEMPLATE_FROZEN' using errcode = '55000';
  end if;
  if p_competencies is null or jsonb_typeof(p_competencies) <> 'array' then
    raise exception 'COMPETENCIES_INVALID' using errcode = '22023';
  end if;
  delete from public.appraisal_competency where cycle_id = p_cycle_id;
  for c in select * from jsonb_array_elements(p_competencies) loop
    i := i + 1;
    insert into public.appraisal_competency (cycle_id, tenant_id, name, weight_pct, sort_order)
    values (p_cycle_id, v_cycle.tenant_id, btrim(c ->> 'name'), (c ->> 'weight_pct')::numeric, i);
  end loop;
end;
$$;
revoke execute on function public.set_cycle_competencies(uuid, jsonb) from public, anon;
grant execute on function public.set_cycle_competencies(uuid, jsonb) to authenticated;

-- Publish: weights must sum to 100; eligible staff get an appraisal each, with a frozen copy of the template.
create or replace function public.publish_appraisal_cycle(p_cycle_id uuid, p_rater_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cycle    public.appraisal_cycle%rowtype;
  v_sum      numeric;
  v_count    integer;
  v_snapshot jsonb;
  v_made     integer;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_cycle from public.appraisal_cycle where id = p_cycle_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'CYCLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_cycle.status <> 'draft' then
    raise exception 'CYCLE_ALREADY_PUBLISHED' using errcode = '55000';
  end if;
  select coalesce(sum(weight_pct), 0), count(*) into v_sum, v_count from public.appraisal_competency where cycle_id = p_cycle_id;
  if v_count = 0 or v_sum <> 100 then
    raise exception 'WEIGHTS_NOT_100: weights sum to %', v_sum using errcode = '23514';
  end if;
  if p_rater_id is not null and not exists (select 1 from public.app_user where user_id = p_rater_id and tenant_id = v_cycle.tenant_id and status = 'active') then
    raise exception 'RATER_NOT_FOUND' using errcode = 'P0002';
  end if;

  select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'weight_pct', weight_pct) order by sort_order) into v_snapshot
    from public.appraisal_competency where cycle_id = p_cycle_id;

  update public.appraisal_cycle set status = 'published', published_at = clock_timestamp() where id = p_cycle_id;

  insert into public.appraisal (tenant_id, campus_id, cycle_id, staff_id, rater_id, template_snapshot)
  select s.tenant_id, s.campus_id, p_cycle_id, s.id,
         coalesce(p_rater_id,
                  (select au.user_id from public.user_campus uc join public.app_user au on au.user_id = uc.user_id
                    where uc.campus_id = s.campus_id and uc.is_active and au.app_role = 'principal' and au.status = 'active' and au.tenant_id = s.tenant_id
                    order by au.full_name limit 1),
                  (select auth.uid())),
         v_snapshot
    from public.staff s
   where s.tenant_id = v_cycle.tenant_id
     and s.employment_status in ('active', 'on_leave', 'suspended')
     and (v_cycle.closes_on - s.doj) >= v_cycle.min_service_days
  on conflict (cycle_id, staff_id) do nothing;
  get diagnostics v_made = row_count;
  return v_made;
end;
$$;
revoke execute on function public.publish_appraisal_cycle(uuid, uuid) from public, anon;
grant execute on function public.publish_appraisal_cycle(uuid, uuid) to authenticated;

create or replace function public.reassign_appraisal_rater(p_appraisal_id uuid, p_rater_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.app_user where user_id = p_rater_id and tenant_id = app.auth_tenant_id() and status = 'active') then
    raise exception 'RATER_NOT_FOUND' using errcode = 'P0002';
  end if;
  update public.appraisal set rater_id = p_rater_id where id = p_appraisal_id and tenant_id = app.auth_tenant_id() and status = 'in_progress';
  if not found then
    raise exception 'APPRAISAL_NOT_EDITABLE' using errcode = '55000';
  end if;
end;
$$;
revoke execute on function public.reassign_appraisal_rater(uuid, uuid) from public, anon;
grant execute on function public.reassign_appraisal_rater(uuid, uuid) to authenticated;

-- ── scoring ───────────────────────────────────────────────────────────────

-- [{"competency_id": "...", "rating": 4}, ...] - only while in progress, only by the rater.
create or replace function public.save_appraisal_scores(p_appraisal_id uuid, p_scores jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.appraisal%rowtype;
  s   jsonb;
  v_rating integer;
  v_comp   uuid;
begin
  select * into v_a from public.appraisal where id = p_appraisal_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'APPRAISAL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.rater_id <> (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_a.status <> 'in_progress' then
    raise exception 'APPRAISAL_NOT_EDITABLE' using errcode = '55000';
  end if;
  if p_scores is null or jsonb_typeof(p_scores) <> 'array' then
    raise exception 'SCORES_INVALID' using errcode = '22023';
  end if;
  for s in select * from jsonb_array_elements(p_scores) loop
    v_comp := (s ->> 'competency_id')::uuid;
    v_rating := (s ->> 'rating')::integer;
    if v_rating is null or v_rating not between 1 and 5 then
      raise exception 'RATING_OUT_OF_RANGE' using errcode = '22023';
    end if;
    if not exists (select 1 from jsonb_array_elements(v_a.template_snapshot) t where (t ->> 'id')::uuid = v_comp) then
      raise exception 'COMPETENCY_NOT_IN_APPRAISAL' using errcode = '22023';
    end if;
    insert into public.appraisal_score (appraisal_id, competency_id, tenant_id, rating)
    values (p_appraisal_id, v_comp, v_a.tenant_id, v_rating)
    on conflict (appraisal_id, competency_id) do update set rating = excluded.rating;
  end loop;
end;
$$;
revoke execute on function public.save_appraisal_scores(uuid, jsonb) from public, anon;
grant execute on function public.save_appraisal_scores(uuid, jsonb) to authenticated;

-- sum(weight x rating / 5), from the weights frozen on the appraisal.
create or replace function app.fn_appraisal_score(p_appraisal_id uuid)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select round(sum((t ->> 'weight_pct')::numeric * sc.rating / 5.0), 2)
    from public.appraisal a
    cross join lateral jsonb_array_elements(a.template_snapshot) t
    join public.appraisal_score sc on sc.appraisal_id = a.id and sc.competency_id = (t ->> 'id')::uuid
   where a.id = p_appraisal_id;
$$;
revoke execute on function app.fn_appraisal_score(uuid) from public, anon, authenticated;

create or replace function public.release_appraisal(p_appraisal_id uuid)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a       public.appraisal%rowtype;
  v_needed  integer;
  v_scored  integer;
  v_total   numeric;
begin
  select * into v_a from public.appraisal where id = p_appraisal_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'APPRAISAL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.rater_id <> (select auth.uid()) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_a.status <> 'in_progress' then
    raise exception 'APPRAISAL_NOT_EDITABLE' using errcode = '55000';
  end if;
  v_needed := jsonb_array_length(v_a.template_snapshot);
  select count(*) into v_scored from public.appraisal_score where appraisal_id = p_appraisal_id;
  if v_scored < v_needed then
    raise exception 'SCORES_INCOMPLETE' using errcode = '55000';
  end if;
  v_total := app.fn_appraisal_score(p_appraisal_id);
  update public.appraisal set status = 'released', total_score = v_total, released_at = clock_timestamp() where id = p_appraisal_id;
  return v_total;
end;
$$;
revoke execute on function public.release_appraisal(uuid) from public, anon;
grant execute on function public.release_appraisal(uuid) to authenticated;

-- ── the appraisee ─────────────────────────────────────────────────────────

-- What the appraisee may see of their own appraisal in a cycle. Before release: the status and nothing else.
create or replace function public.get_my_appraisal(p_cycle_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_a public.appraisal%rowtype;
begin
  select a.* into v_a
    from public.appraisal a join public.staff s on s.id = a.staff_id
   where a.cycle_id = p_cycle_id and a.tenant_id = app.auth_tenant_id() and s.user_id = (select auth.uid());
  if not found then
    return null;
  end if;
  if v_a.status = 'in_progress' then
    return jsonb_build_object('id', v_a.id, 'status', v_a.status, 'scores', null, 'total_score', null);
  end if;
  return jsonb_build_object(
    'id', v_a.id, 'status', v_a.status, 'total_score', v_a.total_score, 'released_at', v_a.released_at,
    'acknowledged_at', v_a.acknowledged_at, 'appraisee_comment', v_a.appraisee_comment,
    'scores', coalesce((
      select jsonb_agg(jsonb_build_object('competency', t ->> 'name', 'weight_pct', (t ->> 'weight_pct')::numeric, 'rating', sc.rating) order by ord)
        from jsonb_array_elements(v_a.template_snapshot) with ordinality as x(t, ord)
        join public.appraisal_score sc on sc.appraisal_id = v_a.id and sc.competency_id = (t ->> 'id')::uuid), '[]'::jsonb));
end;
$$;
revoke execute on function public.get_my_appraisal(uuid) from public, anon;
grant execute on function public.get_my_appraisal(uuid) to authenticated;

create or replace function app.fn_appraisee_appraisal(p_appraisal_id uuid)
returns public.appraisal
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.appraisal%rowtype;
begin
  select a.* into v_a
    from public.appraisal a join public.staff s on s.id = a.staff_id
   where a.id = p_appraisal_id and a.tenant_id = app.auth_tenant_id() and s.user_id = (select auth.uid())
   for update of a;
  if not found then
    raise exception 'APPRAISAL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.status not in ('released', 'awaiting_acknowledgement') then
    raise exception 'APPRAISAL_NOT_RELEASED' using errcode = '55000';
  end if;
  return v_a;
end;
$$;
revoke execute on function app.fn_appraisee_appraisal(uuid) from public, anon, authenticated;

create or replace function public.acknowledge_appraisal(p_appraisal_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.appraisal%rowtype;
begin
  v_a := app.fn_appraisee_appraisal(p_appraisal_id);
  update public.appraisal set status = 'final', acknowledged_at = clock_timestamp() where id = v_a.id;
end;
$$;
revoke execute on function public.acknowledge_appraisal(uuid) from public, anon;
grant execute on function public.acknowledge_appraisal(uuid) to authenticated;

-- The appraisee disagrees: their response (up to 2000 characters) is stored, the Owner can read it, and
-- the appraisal stays awaiting acknowledgement.
create or replace function public.dispute_appraisal(p_appraisal_id uuid, p_comment text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.appraisal%rowtype;
begin
  v_a := app.fn_appraisee_appraisal(p_appraisal_id);
  if char_length(btrim(coalesce(p_comment, ''))) = 0 then
    raise exception 'COMMENT_REQUIRED' using errcode = '22023';
  end if;
  if char_length(p_comment) > 2000 then
    raise exception 'COMMENT_TOO_LONG' using errcode = '22001';
  end if;
  update public.appraisal set status = 'awaiting_acknowledgement', appraisee_comment = btrim(p_comment) where id = v_a.id;
end;
$$;
revoke execute on function public.dispute_appraisal(uuid, text) from public, anon;
grant execute on function public.dispute_appraisal(uuid, text) to authenticated;

-- HR or the Owner closes an appraisal that is released or disputed (after hearing the appraisee).
create or replace function public.finalise_appraisal(p_appraisal_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_a public.appraisal%rowtype;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_a from public.appraisal where id = p_appraisal_id and tenant_id = app.auth_tenant_id() for update;
  if not found then
    raise exception 'APPRAISAL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_a.status not in ('released', 'awaiting_acknowledgement') then
    raise exception 'APPRAISAL_NOT_RELEASED' using errcode = '55000';
  end if;
  update public.appraisal set status = 'final', finalised_by = (select auth.uid()) where id = p_appraisal_id;
end;
$$;
revoke execute on function public.finalise_appraisal(uuid) from public, anon;
grant execute on function public.finalise_appraisal(uuid) to authenticated;

-- ── the report: eligible staff only ───────────────────────────────────────

create or replace function public.appraisal_cycle_report(p_cycle_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_cycle    public.appraisal_cycle%rowtype;
  v_excluded jsonb;
  v_summary  jsonb;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_cycle from public.appraisal_cycle where id = p_cycle_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CYCLE_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('staff_id', s.id, 'name', s.full_name, 'employee_code', s.employee_code, 'service_days', v_cycle.closes_on - s.doj) order by s.full_name), '[]'::jsonb)
    into v_excluded
    from public.staff s
   where s.tenant_id = v_cycle.tenant_id and s.employment_status in ('active', 'on_leave', 'suspended')
     and not exists (select 1 from public.appraisal a where a.cycle_id = p_cycle_id and a.staff_id = s.id);
  select jsonb_build_object(
           'eligible', count(*),
           'scored', count(*) filter (where a.total_score is not null),
           'average_score', round(avg(a.total_score), 2),
           'in_progress', count(*) filter (where a.status = 'in_progress'),
           'released', count(*) filter (where a.status = 'released'),
           'awaiting_acknowledgement', count(*) filter (where a.status = 'awaiting_acknowledgement'),
           'final', count(*) filter (where a.status = 'final'))
    into v_summary
    from public.appraisal a where a.cycle_id = p_cycle_id;
  return v_summary || jsonb_build_object('excluded', v_excluded, 'excluded_count', jsonb_array_length(v_excluded), 'min_service_days', v_cycle.min_service_days, 'closes_on', v_cycle.closes_on);
end;
$$;
revoke execute on function public.appraisal_cycle_report(uuid) from public, anon;
grant execute on function public.appraisal_cycle_report(uuid) to authenticated;
