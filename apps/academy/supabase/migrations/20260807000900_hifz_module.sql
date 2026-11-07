-- Hifz / Quran module: halqas (circles), which students are in them, and the
-- teacher's daily lesson record.
--
-- A day's record per student has up to three lessons, as madrasas keep it:
--   sabaq  - the new portion memorised today
--   sabqi  - revision of the recent juz
--   manzil - revision of older juz
-- each with where it started and ended (para / juz number 1-30 and a surah or
-- page reference as free text), lines, mistakes, tajweed mistakes and a grade.
-- Progress is the highest para reached in sabaq. Streams cover hifz, nazra
-- (reading) and qaida (beginners), which use the same lesson shape.

create table public.halqa (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  name        text not null check (length(btrim(name)) between 1 and 100),
  stream      text not null default 'hifz' check (stream in ('hifz', 'nazra', 'qaida')),
  teacher_id  uuid references public.app_user(user_id),
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);
create unique index uq_halqa_name on public.halqa (campus_id, lower(name)) where is_active;
create index idx_halqa_scope on public.halqa (tenant_id, campus_id);
create index idx_halqa_teacher on public.halqa (teacher_id) where teacher_id is not null;

create table public.halqa_member (
  halqa_id    uuid not null references public.halqa(id) on delete cascade,
  student_id  uuid not null references public.student(id) on delete cascade,
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  joined_on   date not null default current_date,
  left_on     date,
  primary key (halqa_id, student_id)
);
create unique index uq_halqa_member_active on public.halqa_member (student_id) where left_on is null;
create index idx_halqa_member_scope on public.halqa_member (tenant_id, campus_id);

create table public.hifz_lesson (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  campus_id        uuid not null references public.campus(id) on delete cascade,
  halqa_id         uuid not null references public.halqa(id) on delete cascade,
  student_id       uuid not null references public.student(id) on delete cascade,
  lesson_date      date not null,
  lesson_type      text not null check (lesson_type in ('sabaq', 'sabqi', 'manzil')),
  para_from        smallint check (para_from between 1 and 30),
  para_to          smallint check (para_to between 1 and 30),
  portion          text check (portion is null or length(portion) <= 200),
  lines            smallint check (lines between 0 and 1000),
  mistakes         smallint not null default 0 check (mistakes between 0 and 500),
  tajweed_mistakes smallint not null default 0 check (tajweed_mistakes between 0 and 500),
  grade            text check (grade in ('excellent', 'good', 'average', 'weak', 'repeat')),
  recorded_by      uuid not null default auth.uid() references auth.users(id),
  created_at       timestamptz not null default now(),
  constraint uq_hifz_lesson_day unique (student_id, lesson_date, lesson_type),
  constraint chk_hifz_para_order check (para_from is null or para_to is null or para_to >= para_from)
);
create index idx_hifz_lesson_student on public.hifz_lesson (student_id, lesson_date desc);
create index idx_hifz_lesson_scope on public.hifz_lesson (tenant_id, campus_id, lesson_date desc);
create index idx_hifz_lesson_halqa on public.hifz_lesson (halqa_id, lesson_date);

alter table public.halqa enable row level security;
alter table public.halqa_member enable row level security;
alter table public.hifz_lesson enable row level security;

create or replace function app.fn_hifz_staff()
returns boolean
language sql
stable
set search_path = ''
as $$
  select app.auth_role() not in ('parent', 'student', 'none');
$$;

create policy halqa_read on public.halqa for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_hifz_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy halqa_member_read on public.halqa_member for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_hifz_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));
create policy hifz_lesson_read on public.hifz_lesson for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_hifz_staff()
         and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids())));

select app.fn_block_portal_roles('public.halqa');
select app.fn_block_portal_roles('public.halqa_member');
select app.fn_block_portal_roles('public.hifz_lesson');

-- ── setup: leadership manages halqas and who is in them ───────────────────

create or replace function app.fn_assert_hifz_admin(p_campus_id uuid)
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if app.auth_tenant_id() is null or app.auth_role() not in ('super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
end;
$$;

revoke execute on function app.fn_assert_hifz_admin(uuid) from public, anon, authenticated;

create or replace function public.save_halqa(p_campus_id uuid, p_name text, p_stream text, p_teacher_id uuid, p_halqa_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  perform app.fn_assert_hifz_admin(p_campus_id);
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_teacher_id is not null and not exists (select 1 from public.app_user where user_id = p_teacher_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'TEACHER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_halqa_id is null then
    insert into public.halqa (tenant_id, campus_id, name, stream, teacher_id)
    values (app.auth_tenant_id(), p_campus_id, btrim(p_name), p_stream, p_teacher_id)
    returning id into v_id;
  else
    update public.halqa set name = btrim(p_name), stream = p_stream, teacher_id = p_teacher_id
     where id = p_halqa_id and campus_id = p_campus_id and tenant_id = app.auth_tenant_id()
    returning id into v_id;
    if v_id is null then
      raise exception 'HALQA_NOT_FOUND' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;
revoke execute on function public.save_halqa(uuid, text, text, uuid, uuid) from public, anon;
grant execute on function public.save_halqa(uuid, text, text, uuid, uuid) to authenticated;

create or replace function public.set_halqa_member(p_halqa_id uuid, p_student_id uuid, p_member boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_halqa public.halqa%rowtype;
begin
  select * into v_halqa from public.halqa where id = p_halqa_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'HALQA_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_assert_hifz_admin(v_halqa.campus_id);

  if p_member then
    if not exists (select 1 from public.student where id = p_student_id and campus_id = v_halqa.campus_id and deleted_at is null) then
      raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
    end if;
    -- A student is in one halqa at a time: joining a new one ends the old one.
    update public.halqa_member set left_on = current_date where student_id = p_student_id and left_on is null and halqa_id <> p_halqa_id;
    insert into public.halqa_member (halqa_id, student_id, tenant_id, campus_id)
    values (p_halqa_id, p_student_id, v_halqa.tenant_id, v_halqa.campus_id)
    on conflict (halqa_id, student_id) do update set left_on = null, joined_on = current_date;
  else
    update public.halqa_member set left_on = current_date where halqa_id = p_halqa_id and student_id = p_student_id and left_on is null;
  end if;
end;
$$;
revoke execute on function public.set_halqa_member(uuid, uuid, boolean) from public, anon;
grant execute on function public.set_halqa_member(uuid, uuid, boolean) to authenticated;

-- ── the daily record: the halqa's teacher, or leadership ──────────────────

create or replace function public.record_hifz_lesson(
  p_halqa_id         uuid,
  p_student_id       uuid,
  p_lesson_date      date,
  p_lesson_type      text,
  p_para_from        smallint,
  p_para_to          smallint,
  p_portion          text,
  p_lines            smallint,
  p_mistakes         smallint,
  p_tajweed_mistakes smallint,
  p_grade            text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_halqa public.halqa%rowtype;
  v_id    uuid;
begin
  select * into v_halqa from public.halqa where id = p_halqa_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'HALQA_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not (v_halqa.teacher_id = (select auth.uid())
          or (app.auth_role() in ('super_admin', 'owner', 'principal', 'vice_principal', 'head_of_department')
              and (app.auth_role() in ('super_admin', 'owner') or v_halqa.campus_id = any(app.auth_campus_ids())))) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.halqa_member where halqa_id = p_halqa_id and student_id = p_student_id and left_on is null) then
    raise exception 'NOT_IN_HALQA' using errcode = '22023';
  end if;
  if p_lesson_date is null or p_lesson_date > current_date then
    raise exception 'DATE_INVALID' using errcode = '22023';
  end if;

  insert into public.hifz_lesson (tenant_id, campus_id, halqa_id, student_id, lesson_date, lesson_type, para_from, para_to, portion, lines, mistakes, tajweed_mistakes, grade)
  values (v_halqa.tenant_id, v_halqa.campus_id, p_halqa_id, p_student_id, p_lesson_date, p_lesson_type, p_para_from, p_para_to,
          nullif(btrim(p_portion), ''), p_lines, coalesce(p_mistakes, 0), coalesce(p_tajweed_mistakes, 0), p_grade)
  on conflict (student_id, lesson_date, lesson_type) do update
     set halqa_id = excluded.halqa_id, para_from = excluded.para_from, para_to = excluded.para_to, portion = excluded.portion,
         lines = excluded.lines, mistakes = excluded.mistakes, tajweed_mistakes = excluded.tajweed_mistakes, grade = excluded.grade,
         recorded_by = auth.uid()
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.record_hifz_lesson(uuid, uuid, date, text, smallint, smallint, text, smallint, smallint, smallint, text) from public, anon;
grant execute on function public.record_hifz_lesson(uuid, uuid, date, text, smallint, smallint, text, smallint, smallint, smallint, text) to authenticated;

-- Progress per student in a halqa: highest para reached in sabaq, lessons and
-- mistakes in the last 30 days, last lesson date. Invoker: RLS scopes it.
create or replace function public.halqa_progress(p_halqa_id uuid)
returns table (student_id uuid, student_name text, gr_number text, highest_para smallint, lessons_30d int, mistakes_30d int, last_lesson date)
language sql
stable
set search_path = ''
as $$
  select s.id, s.name_en, s.gr_number,
         (select max(l.para_to) from public.hifz_lesson l where l.student_id = s.id and l.lesson_type = 'sabaq'),
         (select count(*)::int from public.hifz_lesson l where l.student_id = s.id and l.lesson_date > current_date - 30),
         (select coalesce(sum(l.mistakes + l.tajweed_mistakes), 0)::int from public.hifz_lesson l where l.student_id = s.id and l.lesson_date > current_date - 30),
         (select max(l.lesson_date) from public.hifz_lesson l where l.student_id = s.id)
    from public.halqa_member m
    join public.student s on s.id = m.student_id
   where m.halqa_id = p_halqa_id and m.left_on is null
   order by s.name_en;
$$;
revoke execute on function public.halqa_progress(uuid) from public, anon;
grant execute on function public.halqa_progress(uuid) to authenticated;
