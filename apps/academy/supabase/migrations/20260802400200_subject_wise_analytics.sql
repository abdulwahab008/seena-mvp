-- FR-J06: subject-wise student analytics.
--
-- "As a parent, I want to see my child's subject performance across terms
-- against the section average, so that I know whether they are improving or
-- slipping."
--
-- ── Materialise on lock, never compute on read ──────────────────────────
--
-- The Notes: averaging 3 terms x 12 subjects x 40 students on read is "the
-- query that flattens the parent portal on results day, which is the one day
-- everyone logs in at once". So the section average is a MATERIALIZED VIEW,
-- app.mv_subject_term_average, refreshed
--   * when a paper is locked (trg_refresh_subject_averages on mark_lock — it
--     fires after FR-J02's trg_enqueue_result_compute, which is what writes
--     the subject_result rows this reads), and
--   * hourly by pg_cron (refresh-subject-averages), which also picks up a
--     recompute that did not come through a lock (a break-glass correction).
-- The refresh is CONCURRENTLY, so results-day readers are never blocked by it.
--
-- PostgreSQL cannot refresh part of a materialized view, so
-- fn_refresh_subject_averages(p_exam_term_id) validates the term it was asked
-- about and refreshes the whole view; p_exam_term_id null means "all".
--
-- ── Why the MV lives in the app schema ──────────────────────────────────
--
-- A materialized view cannot carry RLS. FR-K25 learnt that the hard way
-- (20260801790000): left in public it is readable by any signed-in user
-- through the API. app is not exposed by PostgREST, and everything a person
-- reads goes through v_student_subject_trend / v_section_subject_average, whose
-- predicates are the gate.
--
-- ── The suppression rule ────────────────────────────────────────────────
--
-- A section average over fewer than 5 candidates identifies people ("the
-- average is 91, and mine is 95, so..."), and 3 children's mean is not a
-- comparison anyway. Below 5 ranked candidates the average is NULL and the
-- view says "too few students to compare" (AC2). The MV keeps n so the rule
-- is applied in one place, in the views, and can change without a rebuild.
-- "Ranked" is the same population FR-J05 ranks: a result with a percentage,
-- not withheld and not debarred.
--
-- ── What a parent can see ───────────────────────────────────────────────
--
-- Rows come from subject_result, so the existing subject_result_parent_own_child
-- policy (FR-J02, tightened by FR-J08 to hide a withheld term) decides which
-- of THEIR child's terms exist. The only other child-level thing in the view is
-- the aggregate (average, n) — no name, GR number or per-student figure of any
-- other student is reachable (AC3).
--
-- A term with no locked marks has no subject_result row, so it is absent from
-- the series rather than plotted as zero (AC4); an exempt or debarred result
-- (no percentage) is filtered out for the same reason.

-- ═══════════════════════════════════════════════════════════════════════
-- The materialized view
-- ═══════════════════════════════════════════════════════════════════════

create materialized view app.mv_subject_term_average as
select sr.tenant_id,
       sr.campus_id,
       sr.exam_term_id,
       sr.section_id,
       sr.subject_id,
       round(avg(sr.pct), 2)::numeric(5,2) as avg_pct,
       count(*)::int                        as n
  from public.subject_result sr
 where sr.pct is not null
   and not sr.is_blocked
   and not exists (
         select 1 from public.result_withhold w
          where w.enrolment_id = sr.enrolment_id
            and w.exam_term_id = sr.exam_term_id
            and w.released_at is null)
 group by sr.tenant_id, sr.campus_id, sr.exam_term_id, sr.section_id, sr.subject_id;

create unique index uq_mv_subject_avg on app.mv_subject_term_average (exam_term_id, section_id, subject_id);
create index idx_mv_subject_avg_scope on app.mv_subject_term_average (tenant_id, campus_id);

revoke all on app.mv_subject_term_average from public, anon;
-- security_invoker views read it as the caller; app is not exposed by PostgREST.
grant select on app.mv_subject_term_average to authenticated;

comment on materialized view app.mv_subject_term_average is
  'FR-J06: section average per (term, section, subject) over ranked candidates. Refreshed on mark_lock insert and hourly; never computed on read.';

-- ═══════════════════════════════════════════════════════════════════════
-- Refresh
-- ═══════════════════════════════════════════════════════════════════════

create or replace function app.fn_refresh_subject_averages_all()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  refresh materialized view concurrently app.mv_subject_term_average;
  select count(*)::int into v_n from app.mv_subject_term_average;
  insert into public.agg_refresh_log (job_name, status, rows_written) values ('subject_averages', 'ok', v_n);
  return v_n;
exception when others then
  insert into public.agg_refresh_log (job_name, status, error) values ('subject_averages', 'failed', left(sqlerrm, 500));
  raise;
end;
$$;
revoke execute on function app.fn_refresh_subject_averages_all() from public, anon, authenticated;

create or replace function public.fn_refresh_subject_averages(p_exam_term_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
begin
  -- A null tenant is the System path: pg_cron or service_role.
  if v_tenant is not null and app.auth_role() not in ('super_admin', 'owner', 'principal', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_exam_term_id is not null
     and not exists (select 1 from public.exam_term t
                      where t.id = p_exam_term_id and (v_tenant is null or t.tenant_id = v_tenant)) then
    raise exception 'EXAM_TERM_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_refresh_subject_averages_all();
end;
$$;
revoke execute on function public.fn_refresh_subject_averages(uuid) from public, anon;
grant execute on function public.fn_refresh_subject_averages(uuid) to authenticated, service_role;

-- On lock. Never allowed to fail an approval: a stale average is a one-hour
-- inconvenience, a failed sign-off is a teacher locked out of results day.
create or replace function app.tg_refresh_subject_averages()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  begin
    perform app.fn_refresh_subject_averages_all();
  exception when others then
    null;
  end;
  return null;
end;
$$;

-- Named to sort AFTER trg_enqueue_result_compute (triggers fire alphabetically),
-- because the averages read the subject_result rows that trigger writes.
create trigger trg_refresh_subject_averages
  after insert on public.mark_lock
  for each row execute function app.tg_refresh_subject_averages();

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('refresh-subject-averages', '0 * * * *', 'select public.fn_refresh_subject_averages(null);');
  end if;
exception
  when others then null;
end;
$$;

-- ═══════════════════════════════════════════════════════════════════════
-- Term labels
-- ═══════════════════════════════════════════════════════════════════════

-- exam_term has no parent-facing policy (and should not grow one), so a
-- security_invoker view cannot join it for a parent. These expose just a
-- term's name and position, to a caller who already holds a result in it.
create or replace function app.fn_term_name(p_exam_term_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select t.name from public.exam_term t where t.id = p_exam_term_id and t.tenant_id = app.auth_tenant_id();
$$;
revoke execute on function app.fn_term_name(uuid) from public, anon;
grant execute on function app.fn_term_name(uuid) to authenticated;

create or replace function app.fn_term_sequence(p_exam_term_id uuid)
returns smallint
language sql
stable
security definer
set search_path = ''
as $$
  select t.sequence from public.exam_term t where t.id = p_exam_term_id and t.tenant_id = app.auth_tenant_id();
$$;
revoke execute on function app.fn_term_sequence(uuid) from public, anon;
grant execute on function app.fn_term_sequence(uuid) to authenticated;

create or replace function app.fn_subject_name(p_subject_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.name_en from public.subject s where s.id = p_subject_id and s.tenant_id = app.auth_tenant_id();
$$;
revoke execute on function app.fn_subject_name(uuid) from public, anon;
grant execute on function app.fn_subject_name(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════════════
-- What a screen reads
-- ═══════════════════════════════════════════════════════════════════════

create view public.v_student_subject_trend
with (security_invoker = true) as
select sr.tenant_id,
       sr.campus_id,
       e.student_id,
       sr.enrolment_id,
       e.session_id,
       sr.section_id,
       sr.subject_id,
       app.fn_subject_name(sr.subject_id)   as subject_name,
       sr.exam_term_id,
       app.fn_term_name(sr.exam_term_id)    as term_name,
       app.fn_term_sequence(sr.exam_term_id) as term_sequence,
       sr.pct,
       sr.grade_label,
       case when m.n >= 5 then m.avg_pct end                 as section_avg_pct,
       coalesce(m.n, 0)                                      as section_n,
       (m.n is null or m.n < 5)                              as comparison_suppressed,
       case when m.n is null or m.n < 5 then 'too few students to compare' end as comparison_note
  from public.subject_result sr
  join public.enrolment e on e.id = sr.enrolment_id
  left join app.mv_subject_term_average m
         on m.exam_term_id = sr.exam_term_id
        and m.section_id = sr.section_id
        and m.subject_id = sr.subject_id
 where sr.pct is not null
   and not sr.is_blocked;

revoke all on public.v_student_subject_trend from public, anon;
grant select on public.v_student_subject_trend to authenticated;

comment on view public.v_student_subject_trend is
  'FR-J06: one point per locked term for a child and subject, beside the section average (null below 5 ranked candidates). Rows follow subject_result RLS, so a parent sees only their own child.';

-- Teachers and the Principal: the section's averages on their own, per subject
-- and term, without any student in them.
create view public.v_section_subject_average
with (security_invoker = true) as
select m.tenant_id,
       m.campus_id,
       m.section_id,
       m.subject_id,
       app.fn_subject_name(m.subject_id)    as subject_name,
       m.exam_term_id,
       app.fn_term_name(m.exam_term_id)     as term_name,
       app.fn_term_sequence(m.exam_term_id) as term_sequence,
       case when m.n >= 5 then m.avg_pct end as avg_pct,
       m.n,
       (m.n < 5)                             as comparison_suppressed,
       case when m.n < 5 then 'too few students to compare' end as comparison_note
  from app.mv_subject_term_average m
 where m.tenant_id = app.auth_tenant_id()
   and app.auth_role() not in ('parent', 'student')
   and (app.auth_role() in ('super_admin', 'owner') or m.campus_id = any (app.auth_campus_ids()));

revoke all on public.v_section_subject_average from public, anon;
grant select on public.v_section_subject_average to authenticated;
