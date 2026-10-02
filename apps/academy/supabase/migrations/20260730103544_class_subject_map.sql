-- FR-E06 (class-subject curriculum mapping), the capstone tying together
-- FR-E01 (class_level), FR-E04 (subject) and FR-E05 (stream).
--
-- Scope cut: the AC's "40 teaching slots per week" is the campus bell
-- template's total — Module F (Timetable) doesn't exist yet, so there is no
-- real per-campus configurable slot count anywhere in this schema. The
-- weekly-load view below computes the real number (the sum, correctly
-- deduplicated across Islamiyat/Ethics-style alternates); the red-if-over-40
-- comparison itself is a UI-side constant for now, not a stored setting.

create table public.class_subject (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenant(id) on delete cascade,
  campus_id       uuid not null references public.campus(id) on delete cascade,
  session_id      uuid not null references public.academic_session(id) on delete cascade,
  class_level_id  uuid not null references public.class_level(id),
  stream_id       uuid references public.stream(id),
  subject_id      uuid not null references public.subject(id),
  is_compulsory   boolean not null default true,
  elective_bucket smallint,
  choose_n        smallint,
  weekly_periods  smallint not null,
  max_marks       int,
  created_at      timestamptz not null default now(),
  constraint chk_weekly_periods check (weekly_periods between 1 and 12),
  constraint chk_elective_bucket check (is_compulsory or elective_bucket is not null)
);

-- A stream-less mapping (compulsory subjects, or classes below the streaming
-- ordinal) and a stream-specific one are different rows for the same
-- subject — coalesce to a sentinel so the uniqueness check treats "no
-- stream" as its own value rather than NULL's normal not-distinct rules.
create unique index uq_class_subject on public.class_subject (
  session_id, campus_id, class_level_id, (coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)), subject_id
);
create index idx_class_subject_session_class_stream on public.class_subject (session_id, class_level_id, stream_id);

create trigger class_subject_audit after insert or update or delete on public.class_subject
  for each row execute function app.tg_audit_row();

create or replace function public.upsert_class_subject(
  p_campus_id       uuid,
  p_session_id      uuid,
  p_class_level_id  uuid,
  p_subject_id      uuid,
  p_weekly_periods  smallint,
  p_stream_id       uuid default null,
  p_is_compulsory   boolean default true,
  p_elective_bucket smallint default null,
  p_choose_n        smallint default null,
  p_max_marks       int default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- Checked explicitly for the FR's own named error, ahead of the backstop
  -- chk_weekly_periods constraint (which would otherwise fire a generic
  -- constraint-violation message).
  if p_weekly_periods is null or p_weekly_periods < 1 then
    raise exception 'WEEKLY_PERIODS_REQUIRED' using errcode = '23514';
  end if;
  if not p_is_compulsory and p_elective_bucket is null then
    raise exception 'ELECTIVE_BUCKET_REQUIRED' using errcode = '23514';
  end if;

  insert into public.class_subject (
    tenant_id, campus_id, session_id, class_level_id, stream_id, subject_id,
    is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
  ) values (
    app.auth_tenant_id(), p_campus_id, p_session_id, p_class_level_id, p_stream_id, p_subject_id,
    p_is_compulsory, p_elective_bucket, p_choose_n, p_weekly_periods, p_max_marks
  )
  on conflict (session_id, campus_id, class_level_id, (coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)), subject_id)
  do update set
    is_compulsory   = excluded.is_compulsory,
    elective_bucket = excluded.elective_bucket,
    choose_n        = excluded.choose_n,
    weekly_periods  = excluded.weekly_periods,
    max_marks       = excluded.max_marks
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.upsert_class_subject(
  uuid, uuid, uuid, uuid, smallint, uuid, boolean, smallint, smallint, int
) from public, anon;
grant execute on function public.upsert_class_subject(
  uuid, uuid, uuid, uuid, smallint, uuid, boolean, smallint, smallint, int
) to authenticated;

create or replace function public.copy_class_subject_map(
  p_from_class_level_id uuid, p_to_class_level_id uuid, p_session_id uuid, p_campus_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_created int := 0;
  v_skipped int := 0;
  v_row     record;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  for v_row in
    select * from public.class_subject
     where class_level_id = p_from_class_level_id and session_id = p_session_id and campus_id = p_campus_id
  loop
    if exists (
      select 1 from public.class_subject
       where class_level_id = p_to_class_level_id and session_id = p_session_id and campus_id = p_campus_id
         and subject_id = v_row.subject_id
         and coalesce(stream_id, '00000000-0000-0000-0000-000000000000'::uuid)
             = coalesce(v_row.stream_id, '00000000-0000-0000-0000-000000000000'::uuid)
    ) then
      v_skipped := v_skipped + 1;
    else
      insert into public.class_subject (
        tenant_id, campus_id, session_id, class_level_id, stream_id, subject_id,
        is_compulsory, elective_bucket, choose_n, weekly_periods, max_marks
      ) values (
        v_row.tenant_id, v_row.campus_id, v_row.session_id, p_to_class_level_id, v_row.stream_id, v_row.subject_id,
        v_row.is_compulsory, v_row.elective_bucket, v_row.choose_n, v_row.weekly_periods, v_row.max_marks
      );
      v_created := v_created + 1;
    end if;
  end loop;

  return jsonb_build_object('created', v_created, 'skipped', v_skipped);
end;
$$;

revoke execute on function public.copy_class_subject_map(uuid, uuid, uuid, uuid) from public, anon;
grant execute on function public.copy_class_subject_map(uuid, uuid, uuid, uuid) to authenticated;

alter table public.class_subject enable row level security;

create policy class_subject_campus_scope on public.class_subject
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );

-- Mutually-exclusive alternates (Islamiyat/Ethics) collapse to one slot in
-- the weekly total: both resolve to the same "period group" key (the
-- alternate pair's canonical subject id), and DISTINCT ON picks one.
create view public.v_class_weekly_period_load
with (security_invoker = true) as
with normalized as (
  select
    cs.tenant_id, cs.campus_id, cs.session_id, cs.class_level_id, cs.stream_id,
    coalesce(s.alternate_of_subject_id, s.id) as period_group_subject_id,
    cs.weekly_periods
  from public.class_subject cs
  join public.subject s on s.id = cs.subject_id
),
deduped as (
  select distinct on (tenant_id, campus_id, session_id, class_level_id, stream_id, period_group_subject_id)
    tenant_id, campus_id, session_id, class_level_id, stream_id, weekly_periods
  from normalized
)
select tenant_id, campus_id, session_id, class_level_id, stream_id, sum(weekly_periods)::int as total_weekly_periods
  from deduped
 group by tenant_id, campus_id, session_id, class_level_id, stream_id;
