-- FR-B12: record admission test scores per subject and publish an
-- immutable merit-rank snapshot per sitting.
--
-- Scope cuts:
--   * "the merit list renders in under 2 seconds for 60 candidates across
--     3 subjects" is a performance AC, not something pgTAP asserts — the
--     same class of untestable-by-pgTAP claim as every other timing AC in
--     this codebase; the index backing v_admission_merit_rank's join
--     (the unique index on admission_test_score(candidate_id, subject_code),
--     which already leads with candidate_id — the spec's own
--     idx_score_candidate would be a pure duplicate) is the only lever
--     available here and is in place.
--   * "immutable once published" is enforced as: admission_test_sitting
--     gains a locked_at column, set by fn_publish_merit_list() and cleared
--     only by fn_unlock_test_scores() (Principal/Owner/super_admin only);
--     set_test_score()/set_test_attendance() both refuse to write while
--     locked_at is not null. A republish after unlock overwrites the
--     snapshot for the sitting (upsert), which is the documented escape
--     hatch, not a bypass — nothing can touch the snapshot while locked.

alter table public.admission_test_sitting add column locked_at timestamptz;

create table public.admission_test_score (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenant(id) on delete cascade,
  candidate_id uuid not null references public.admission_test_candidate(id) on delete cascade,
  subject_code text not null,
  obtained     numeric(5,2) not null,
  total        numeric(5,2) not null,
  entered_by   uuid references public.app_user(user_id),
  entered_at   timestamptz not null default clock_timestamp(),
  constraint chk_score_range check (obtained >= 0 and total > 0 and obtained <= total)
);

-- Doubles as idx_score_candidate (candidate_id) — it's the leading column.
create unique index uq_score_candidate_subject on public.admission_test_score (candidate_id, subject_code);

create trigger test_score_audit after insert or update or delete on public.admission_test_score
  for each row execute function app.tg_audit_row();

create table public.admission_merit_snapshot (
  sitting_id     uuid not null references public.admission_test_sitting(id) on delete cascade,
  application_id uuid not null references public.admission_application(id) on delete cascade,
  pct            numeric(5,2) not null,
  rank           int not null,
  published_at   timestamptz not null default clock_timestamp(),
  primary key (sitting_id, application_id)
);

create trigger merit_snapshot_audit after insert or update or delete on public.admission_merit_snapshot
  for each row execute function app.tg_audit_row();

-- AC: two candidates on the same percentage — the older child (earlier
-- dob) ranks higher, and the basis is a column in the result so the UI can
-- display it, not just apply it silently.
create view public.v_admission_merit_rank with (security_invoker = true) as
select
  tc.sitting_id,
  tc.application_id,
  tc.id as candidate_id,
  round(sum(ts.obtained) / nullif(sum(ts.total), 0) * 100, 2) as pct,
  ae.dob,
  rank() over (
    partition by tc.sitting_id
    order by (sum(ts.obtained) / nullif(sum(ts.total), 0)) desc, ae.dob asc
  ) as rnk,
  'percentage descending, then date of birth ascending (older ranks higher)'::text as tie_break_basis
from public.admission_test_candidate tc
join public.admission_application aa on aa.id = tc.application_id
join public.admission_enquiry ae on ae.id = aa.enquiry_id
left join public.admission_test_score ts on ts.candidate_id = tc.id
where tc.cancelled_at is null and tc.attendance <> 'absent'
group by tc.sitting_id, tc.application_id, tc.id, ae.dob
having sum(ts.total) is not null;

create or replace function public.set_test_score(p_candidate_id uuid, p_subject_code text, p_obtained numeric, p_total numeric)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id  uuid := app.auth_tenant_id();
  v_sitting_id uuid;
  v_locked_at  timestamptz;
  v_id         uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tc.sitting_id, ts.locked_at into v_sitting_id, v_locked_at
    from public.admission_test_candidate tc
    join public.admission_test_sitting ts on ts.id = tc.sitting_id
   where tc.id = p_candidate_id and tc.tenant_id = v_tenant_id;
  if not found then
    raise exception 'CANDIDATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_locked_at is not null then
    raise exception 'SITTING_LOCKED' using errcode = '55006', detail = 'The merit list is published — a Principal must unlock the sitting first.';
  end if;

  insert into public.admission_test_score (tenant_id, candidate_id, subject_code, obtained, total, entered_by, entered_at)
  values (v_tenant_id, p_candidate_id, p_subject_code, p_obtained, p_total, auth.uid(), clock_timestamp())
  on conflict (candidate_id, subject_code)
  do update set obtained = excluded.obtained, total = excluded.total, entered_by = excluded.entered_by, entered_at = excluded.entered_at
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.set_test_score(uuid, text, numeric, numeric) from public, anon;
grant execute on function public.set_test_score(uuid, text, numeric, numeric) to authenticated;

-- AC: marking a candidate absent nulls their aggregate (handled by the
-- view's join + having), excludes them from the ranking, and flips their
-- application to 'test_absent'.
create or replace function public.set_test_attendance(p_candidate_id uuid, p_attendance public.test_attendance)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id      uuid := app.auth_tenant_id();
  v_application_id uuid;
  v_locked_at      timestamptz;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select tc.application_id, ts.locked_at into v_application_id, v_locked_at
    from public.admission_test_candidate tc
    join public.admission_test_sitting ts on ts.id = tc.sitting_id
   where tc.id = p_candidate_id and tc.tenant_id = v_tenant_id;
  if not found then
    raise exception 'CANDIDATE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_locked_at is not null then
    raise exception 'SITTING_LOCKED' using errcode = '55006', detail = 'The merit list is published — a Principal must unlock the sitting first.';
  end if;

  update public.admission_test_candidate set attendance = p_attendance where id = p_candidate_id;

  if p_attendance = 'absent' then
    update public.admission_application set status = 'test_absent' where id = v_application_id;
  end if;
end;
$$;

revoke execute on function public.set_test_attendance(uuid, public.test_attendance) from public, anon;
grant execute on function public.set_test_attendance(uuid, public.test_attendance) to authenticated;

create or replace function public.fn_publish_merit_list(p_sitting_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_locked_at timestamptz;
  v_count     int;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer', 'exam_controller') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  select locked_at into v_locked_at from public.admission_test_sitting where id = p_sitting_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SITTING_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_locked_at is not null then
    raise exception 'ALREADY_PUBLISHED' using errcode = '55006', detail = 'This sitting is already published — unlock it before republishing.';
  end if;

  insert into public.admission_merit_snapshot (sitting_id, application_id, pct, rank, published_at)
  select sitting_id, application_id, pct, rnk, clock_timestamp()
    from public.v_admission_merit_rank
   where sitting_id = p_sitting_id
  on conflict (sitting_id, application_id) do update set pct = excluded.pct, rank = excluded.rank, published_at = excluded.published_at;
  get diagnostics v_count = row_count;

  delete from public.admission_merit_snapshot
   where sitting_id = p_sitting_id
     and application_id not in (select application_id from public.v_admission_merit_rank where sitting_id = p_sitting_id);

  update public.admission_test_sitting set locked_at = clock_timestamp() where id = p_sitting_id;

  return jsonb_build_object('sitting_id', p_sitting_id, 'published_count', v_count);
end;
$$;

revoke execute on function public.fn_publish_merit_list(uuid) from public, anon;
grant execute on function public.fn_publish_merit_list(uuid) to authenticated;

create or replace function public.fn_unlock_test_scores(p_sitting_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  update public.admission_test_sitting set locked_at = null where id = p_sitting_id and tenant_id = v_tenant_id;
  if not found then
    raise exception 'SITTING_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;

revoke execute on function public.fn_unlock_test_scores(uuid) from public, anon;
grant execute on function public.fn_unlock_test_scores(uuid) to authenticated;

alter table public.admission_test_score enable row level security;
alter table public.admission_merit_snapshot enable row level security;

create policy test_score_tenant_read on public.admission_test_score
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (
      app.auth_role() in ('super_admin', 'owner')
      or candidate_id in (
        select tc.id from public.admission_test_candidate tc
        join public.admission_test_sitting sit on sit.id = tc.sitting_id
        where sit.campus_id = any(app.auth_campus_ids())
      )
    )
  );

create policy merit_snapshot_tenant_read on public.admission_merit_snapshot
  for select to authenticated
  using (
    sitting_id in (
      select id from public.admission_test_sitting
      where tenant_id = app.auth_tenant_id()
        and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
    )
  );
