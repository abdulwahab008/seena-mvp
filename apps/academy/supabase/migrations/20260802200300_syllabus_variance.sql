-- FR-H12: syllabus progress variance against plan.
--
-- For every (section, subject) the Principal needs three numbers: how much of
-- the syllabus SHOULD be covered by today (expected), how much is (actual),
-- and the gap (variance). Both are weighted by planned_periods, exactly like
-- coverage_pct() in FR-H11.
--
--   expected  a unit is due once its target_month has begun; a unit whose
--             target_month is still in the future contributes 0. A pair where
--             NO unit has a target_month has no plan at all: expected is NULL
--             and it is classified 'no_plan', never 'behind';
--   actual    completed units by the same weighting;
--   variance  actual - expected, two decimals;
--   class     behind when variance < -5.00, otherwise on_track (so 57 against
--             60 is on track, 43 against 60 is behind by 17.00).
--
-- Why a materialised view: a campus of 42 sections x 8 subjects is 336 pairs,
-- each needing a per-unit weighted sum. Computed live per dashboard load that
-- does not scale to a 20-campus tenant, so the figures are rebuilt daily at
-- 05:00 PKT (00:00 UTC) and read from app.mv_syllabus_variance. The refresh is
-- CONCURRENTLY (the unique index uq_mv_variance_pair makes that possible), so
-- the Principal is never locked out while it runs. The matview lives in the
-- app schema, which PostgREST does not expose; public.v_syllabus_variance is
-- the security_invoker view that carries the tenant, campus and role filter a
-- matview cannot.
--
-- Strikes, floods and unscheduled closures are routine, so a 'behind' pair can
-- carry an acknowledged reason (syllabus_variance_ack) instead of nagging
-- permanently; the classification is unchanged, the view shows the reason.

create or replace function app.fn_classify_variance(p_expected numeric, p_actual numeric)
returns table (variance_pct numeric, classification text)
language sql
immutable
set search_path = ''
as $$
  select case when p_expected is null then null else round(p_actual - p_expected, 2) end,
         case when p_expected is null then 'no_plan'
              when round(p_actual - p_expected, 2) < -5.00 then 'behind'
              else 'on_track' end;
$$;

create or replace function public.classify_syllabus_variance(p_expected numeric, p_actual numeric)
returns table (variance_pct numeric, classification text)
language sql
immutable
set search_path = ''
as $$
  select * from app.fn_classify_variance(p_expected, p_actual);
$$;
revoke execute on function public.classify_syllabus_variance(numeric, numeric) from public, anon;
grant execute on function public.classify_syllabus_variance(numeric, numeric) to authenticated;

create materialized view app.mv_syllabus_variance as
with pairs as (
  select s.id as section_id, s.tenant_id, s.campus_id, s.session_id, s.class_level_id, u.subject_id
    from public.class_section s
    join public.syllabus_unit u on u.campus_id = s.campus_id and u.session_id = s.session_id and u.class_level_id = s.class_level_id
   where s.is_active
   group by s.id, s.tenant_id, s.campus_id, s.session_id, s.class_level_id, u.subject_id
),
picked as (
  select p.*, app.fn_section_board(p.section_id, p.subject_id) as board from pairs p
),
w as (
  select k.section_id, k.tenant_id, k.campus_id, k.session_id, k.subject_id, u.target_month, (c.status = 'completed') as done,
         case when sum(u.planned_periods) over (partition by k.section_id, k.subject_id) = 0 then 1 else u.planned_periods end as wt,
         case when sum(u.planned_periods) over (partition by k.section_id, k.subject_id) = 0
              then count(*) over (partition by k.section_id, k.subject_id)
              else sum(u.planned_periods) over (partition by k.section_id, k.subject_id) end as denom
    from picked k
    join public.syllabus_unit u
      on u.campus_id = k.campus_id and u.session_id = k.session_id and u.class_level_id = k.class_level_id and u.subject_id = k.subject_id and u.board = k.board
    left join public.syllabus_coverage c on c.syllabus_unit_id = u.id and c.section_id = k.section_id and c.subject_id = k.subject_id
),
agg as (
  select section_id, tenant_id, campus_id, session_id, subject_id,
         round(100.0 * coalesce(sum(wt) filter (where done), 0) / max(denom), 2) as actual_pct,
         case when count(target_month) = 0 then null
              else round(100.0 * coalesce(sum(wt) filter (where target_month <= date_trunc('month', app.fn_karachi_today())::date), 0) / max(denom), 2) end as expected_pct
    from w
   group by section_id, tenant_id, campus_id, session_id, subject_id
)
select a.tenant_id, a.campus_id, a.session_id, a.section_id, a.subject_id, a.expected_pct, a.actual_pct, c.variance_pct, c.classification,
       now() as computed_at
  from agg a cross join lateral app.fn_classify_variance(a.expected_pct, a.actual_pct) c
with data;

-- Unique over the pair is what lets the daily refresh run CONCURRENTLY.
create unique index uq_mv_variance_pair on app.mv_syllabus_variance (section_id, subject_id);
create index idx_mv_variance on app.mv_syllabus_variance (campus_id, classification, variance_pct);
grant select on app.mv_syllabus_variance to authenticated;

create table public.syllabus_variance_ack (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  section_id      uuid not null references public.class_section(id) on delete cascade,
  subject_id      uuid not null references public.subject(id),
  reason          text not null check (char_length(btrim(reason)) between 3 and 300),
  acknowledged_by uuid references auth.users(id),
  acknowledged_at timestamptz not null default now(),
  constraint uq_variance_ack unique (section_id, subject_id, session_id)
);
create index idx_variance_ack_tenant on public.syllabus_variance_ack (tenant_id, campus_id);
create index idx_variance_ack_subject on public.syllabus_variance_ack (subject_id);
create index idx_variance_ack_session on public.syllabus_variance_ack (session_id);
create trigger syllabus_variance_ack_audit after insert or update or delete on public.syllabus_variance_ack
  for each row execute function app.tg_audit_row();
alter table public.syllabus_variance_ack enable row level security;
create policy variance_ack_read on public.syllabus_variance_ack for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));

create view public.v_syllabus_variance with (security_invoker = true) as
select m.campus_id, m.session_id, m.section_id, m.subject_id,
       cl.name_en as class_name, cs.name as section_name, sub.name_en as subject_name,
       m.expected_pct, m.actual_pct, m.variance_pct, m.classification, m.computed_at,
       a.reason as ack_reason, a.acknowledged_at
  from app.mv_syllabus_variance m
  join public.class_section cs on cs.id = m.section_id
  join public.class_level cl on cl.id = cs.class_level_id
  join public.subject sub on sub.id = m.subject_id
  left join public.syllabus_variance_ack a on a.section_id = m.section_id and a.subject_id = m.subject_id and a.session_id = m.session_id
 where m.tenant_id = app.auth_tenant_id()
   and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
   and (app.auth_role() in ('owner', 'super_admin') or m.campus_id = any (app.auth_campus_ids()));
grant select on public.v_syllabus_variance to authenticated;

-- p_campus_id null: the scheduled whole-platform refresh (service role / cron
-- only). With a campus: an on-demand refresh by that campus's leadership; the
-- matview is one object, so the work is the same, but it is campus-checked.
create or replace function public.refresh_syllabus_variance(p_campus_id uuid default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  if p_campus_id is null then
    if (select auth.uid()) is not null then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  else
    if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
       or not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id())
       or (app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any (app.auth_campus_ids()))) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;
  refresh materialized view concurrently app.mv_syllabus_variance;
  select count(*)::int into v_n from app.mv_syllabus_variance;
  insert into public.agg_refresh_log (job_name, status, rows_written) values ('syllabus_variance_refresh', 'ok', v_n);
  return v_n;
exception when others then
  insert into public.agg_refresh_log (job_name, status, error) values ('syllabus_variance_refresh', 'failed', left(sqlerrm, 500));
  raise;
end;
$$;
revoke execute on function public.refresh_syllabus_variance(uuid) from public, anon;
grant execute on function public.refresh_syllabus_variance(uuid) to authenticated, service_role;

-- 05:00 Asia/Karachi is 00:00 UTC.
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('syllabus_variance_refresh', '0 0 * * *', 'select public.refresh_syllabus_variance();');
  end if;
exception
  when others then null;
end;
$$;

create or replace function public.acknowledge_syllabus_variance(p_section_id uuid, p_subject_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sec public.class_section%rowtype;
begin
  select * into v_sec from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_sec.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.subject where id = p_subject_id and tenant_id = v_sec.tenant_id) then
    raise exception 'SUBJECT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_reason is null or char_length(btrim(p_reason)) < 3 then
    raise exception 'REASON_REQUIRED' using errcode = '22023';
  end if;
  insert into public.syllabus_variance_ack (tenant_id, campus_id, session_id, section_id, subject_id, reason, acknowledged_by)
  values (v_sec.tenant_id, v_sec.campus_id, v_sec.session_id, p_section_id, p_subject_id, left(btrim(p_reason), 300), (select auth.uid()))
  on conflict (section_id, subject_id, session_id) do update set reason = excluded.reason, acknowledged_by = excluded.acknowledged_by, acknowledged_at = now();
end;
$$;
revoke execute on function public.acknowledge_syllabus_variance(uuid, uuid, text) from public, anon;
grant execute on function public.acknowledge_syllabus_variance(uuid, uuid, text) to authenticated;

create or replace function public.clear_syllabus_variance_ack(p_section_id uuid, p_subject_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_sec public.class_section%rowtype;
begin
  select * into v_sec from public.class_section where id = p_section_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'exam_controller')
     or (app.auth_role() not in ('owner', 'super_admin') and not (v_sec.campus_id = any (app.auth_campus_ids()))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  delete from public.syllabus_variance_ack where section_id = p_section_id and subject_id = p_subject_id;
end;
$$;
revoke execute on function public.clear_syllabus_variance_ack(uuid, uuid) from public, anon;
grant execute on function public.clear_syllabus_variance_ack(uuid, uuid) to authenticated;
