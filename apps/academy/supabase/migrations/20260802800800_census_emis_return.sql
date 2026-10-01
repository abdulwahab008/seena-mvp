-- FR-T13: government census and EMIS return generation.
--
-- The whole requirement is the AS-OF DATE. Every naive implementation counts today's
-- enrolment and produces numbers that do not match what the school reported on census day,
-- which is exactly what triggers an audit. Here the roll is reconstructed from the enrolment
-- dates: a student counts if they joined on or before the census date and had not left by it
-- (joined_on <= date and (left_on is null or left_on > date)). So a student who transferred
-- out in April IS counted on a 1 March census even when the return is generated in July, and
-- one admitted on 15 March is not. This relies on enrolment carrying real dates and never
-- being hard-deleted; a soft-deleted (recycle-bin) enrolment is an admission that never
-- validly happened and does not count.
--
-- The return is a set of cells (class x gender, class x age) stored beside the run, with a
-- reconciliation: the cells must sum to the roll size exactly or the run is marked failed.
-- A student with no date of birth lands in an explicit 'unknown' age bucket and the run is
-- flagged incomplete with their count: never silently dropped. Regenerating for the same
-- census date reproduces the same cells (cells_digest) and, because the file builder uses
-- nothing but the cells, a byte-identical file.
--
-- EMIS formats differ per province and are often distributed as a locked Excel workbook, so
-- census_framework_spec carries each framework's labels and output format, and the file layer
-- (lib/census) can either build a workbook or fill a distributed template cell-for-cell.

create index if not exists idx_enrolment_asof on public.enrolment (campus_id, joined_on, left_on);

-- The roll on a date. SECURITY INVOKER: the caller's own campus RLS applies.
create or replace function public.enrolment_as_of(p_campus uuid, p_date date)
returns setof public.enrolment
language sql
stable
set search_path = ''
as $$
  select e.* from public.enrolment e
   where e.campus_id = p_campus and e.deleted_at is null
     and e.joined_on <= p_date and (e.left_on is null or e.left_on > p_date);
$$;
revoke execute on function public.enrolment_as_of(uuid, date) from public, anon;
grant execute on function public.enrolment_as_of(uuid, date) to authenticated;

create table public.census_framework_spec (
  framework     text primary key check (framework in ('punjab_emis', 'sindh_emis', 'kpk_emis', 'pmiu', 'federal')),
  display_name  text not null,
  output_format text not null check (output_format in ('csv', 'xlsx')),
  cell_spec     jsonb not null
);
alter table public.census_framework_spec enable row level security;
create policy census_framework_spec_read on public.census_framework_spec for select to authenticated using (true);

insert into public.census_framework_spec (framework, display_name, output_format, cell_spec) values
  ('punjab_emis', 'Punjab EMIS annual school census', 'xlsx',
   '{"gender_labels":{"male":"Boys","female":"Girls","other":"Other"},"sheets":{"class_gender":"Enrolment by class","age":"Enrolment by age"},"template_map":null}'),
  ('sindh_emis', 'Sindh EMIS school census', 'xlsx',
   '{"gender_labels":{"male":"Male","female":"Female","other":"Other"},"sheets":{"class_gender":"Class-wise enrolment","age":"Age-wise enrolment"},"template_map":null}'),
  ('kpk_emis', 'Khyber Pakhtunkhwa EMIS annual census', 'csv',
   '{"gender_labels":{"male":"Male","female":"Female","other":"Other"},"sheets":{"class_gender":"enrolment_by_class","age":"enrolment_by_age"},"template_map":null}'),
  ('pmiu', 'PMIU school information return', 'csv',
   '{"gender_labels":{"male":"Boys","female":"Girls","other":"Other"},"sheets":{"class_gender":"enrolment_by_class","age":"enrolment_by_age"},"template_map":null}'),
  ('federal', 'Federal Directorate of Education return', 'xlsx',
   '{"gender_labels":{"male":"Male","female":"Female","other":"Other"},"sheets":{"class_gender":"Enrolment","age":"Age profile"},"template_map":null}');

create table public.census_return_run (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  framework         text not null references public.census_framework_spec(framework),
  census_date       date not null,
  status            text not null default 'running' check (status in ('running', 'done', 'failed')),
  file_path         text,
  file_sha256       text check (file_sha256 is null or file_sha256 ~ '^[0-9a-f]{64}$'),
  generated_by      uuid references auth.users(id),
  generated_at      timestamptz not null default clock_timestamp(),
  reconciliation_ok boolean,
  total_students    int,
  unknown_age_count int not null default 0,
  incomplete        boolean not null default false,
  cells_digest      text
);
create index idx_census_run_campus on public.census_return_run (campus_id, census_date desc);
create index idx_census_run_tenant on public.census_return_run (tenant_id);

create table public.census_cell (
  run_id        uuid not null references public.census_return_run(id) on delete cascade,
  dimension_key jsonb not null,
  metric        text not null check (metric in ('enrolment', 'enrolment_by_age')),
  value         int not null check (value >= 0),
  primary key (run_id, metric, dimension_key)
);

create trigger census_return_run_audit after insert or update or delete on public.census_return_run
  for each row execute function app.tg_audit_row();

alter table public.census_return_run enable row level security;
alter table public.census_cell enable row level security;
-- census_run_campus_scope: a Principal sees their own campus's returns; owners see every campus
create policy census_run_campus_scope on public.census_return_run for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids())));
create policy census_cell_read on public.census_cell for select to authenticated
  using (exists (select 1 from public.census_return_run r where r.id = run_id));
-- census_run_write_principal: no direct DML for clients — runs are created only by generate_census_return(),
-- which checks role and campus. (A write policy would let a client insert cells the reconciliation never saw.)

-- ── generation ────────────────────────────────────────────────────────────

-- Age in completed years on the census date, capped at 25; 'unknown' when there is no date of
-- birth (or one after the census date, which is a data-entry error rather than an age).
create or replace function app.fn_census_age(p_dob date, p_date date)
returns text
language sql
immutable
set search_path = ''
as $$
  select case when p_dob is null or p_dob > p_date then 'unknown'
              else least(date_part('year', age(p_date, p_dob))::int, 25)::text end;
$$;

create or replace function app.fn_census_digest(p_run_id uuid)
returns text
language sql
stable
set search_path = ''
as $$
  select md5(coalesce(string_agg(metric || '|' || dimension_key::text || '|' || value::text, ';' order by metric, dimension_key::text), ''))
    from public.census_cell where run_id = p_run_id;
$$;

-- Re-checks a run from the roll as it stood on the census date. Used at the end of generation and
-- by anyone auditing a stored return.
create or replace function public.verify_census_run(p_run_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  r        public.census_return_run%rowtype;
  v_total  int;
  v_cg     int;
  v_age    int;
  v_ok     boolean;
begin
  select * into r from public.census_return_run where id = p_run_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CENSUS_RUN_NOT_FOUND' using errcode = 'P0002';
  end if;
  select count(distinct e.student_id)::int into v_total from public.enrolment e
   where e.campus_id = r.campus_id and e.deleted_at is null and e.joined_on <= r.census_date and (e.left_on is null or e.left_on > r.census_date);
  select coalesce(sum(value), 0)::int into v_cg from public.census_cell where run_id = p_run_id and metric = 'enrolment';
  select coalesce(sum(value), 0)::int into v_age from public.census_cell where run_id = p_run_id and metric = 'enrolment_by_age';
  v_ok := v_cg = v_total and v_age = v_total and coalesce(r.total_students, -1) = v_total;
  update public.census_return_run set reconciliation_ok = v_ok, status = case when v_ok then 'done' else 'failed' end where id = p_run_id;
  return v_ok;
end;
$$;
revoke execute on function public.verify_census_run(uuid) from public, anon;
grant execute on function public.verify_census_run(uuid) to authenticated;

create or replace function public.generate_census_return(p_campus uuid, p_framework text, p_census_date date)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid := app.auth_tenant_id();
  v_id      uuid;
  v_total   int;
  v_unknown int;
begin
  if v_tenant is null or (select auth.uid()) is null then
    raise exception 'UNAUTHENTICATED' using errcode = '28000';
  end if;
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus c where c.id = p_campus and c.tenant_id = v_tenant
                 and (app.auth_role() in ('owner', 'super_admin') or c.id = any (app.auth_campus_ids()))) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.census_framework_spec where framework = p_framework) then
    raise exception 'FRAMEWORK_UNKNOWN' using errcode = '22023';
  end if;
  if p_census_date is null or p_census_date > app.fn_karachi_today() then
    raise exception 'CENSUS_DATE_INVALID' using errcode = '22023', hint = 'The census date cannot be in the future';
  end if;

  insert into public.census_return_run (tenant_id, campus_id, framework, census_date, generated_by)
  values (v_tenant, p_campus, p_framework, p_census_date, (select auth.uid()))
  returning id into v_id;

  -- one row per student: if two enrolments overlap on the date (e.g. a promotion recorded a day early),
  -- the most recently joined one is the one the child sits in
  create temporary table if not exists pg_temp.census_roll (student_id uuid, class_code text, gender text, age text) on commit drop;
  truncate pg_temp.census_roll;
  insert into pg_temp.census_roll
  select distinct on (e.student_id) e.student_id, cl.code, st.gender::text,
         app.fn_census_age(st.dob, p_census_date)
    from public.enrolment e
    join public.student st on st.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
   where e.campus_id = p_campus and e.deleted_at is null and e.joined_on <= p_census_date and (e.left_on is null or e.left_on > p_census_date)
   order by e.student_id, e.joined_on desc, e.created_at desc;

  insert into public.census_cell (run_id, dimension_key, metric, value)
  select v_id, jsonb_build_object('class_code', class_code, 'gender', gender), 'enrolment', count(*)::int from pg_temp.census_roll group by class_code, gender;
  insert into public.census_cell (run_id, dimension_key, metric, value)
  select v_id, jsonb_build_object('class_code', class_code, 'age', age), 'enrolment_by_age', count(*)::int from pg_temp.census_roll group by class_code, age;

  select count(*)::int, count(*) filter (where age = 'unknown')::int into v_total, v_unknown from pg_temp.census_roll;
  update public.census_return_run
     set total_students = v_total, unknown_age_count = v_unknown, incomplete = v_unknown > 0, cells_digest = app.fn_census_digest(v_id)
   where id = v_id;
  perform public.verify_census_run(v_id);   -- the reconciliation assertion: a failing run is marked failed, never 'done'
  return v_id;
end;
$$;
revoke execute on function public.generate_census_return(uuid, text, date) from public, anon;
grant execute on function public.generate_census_return(uuid, text, date) to authenticated;

-- The worker/route records the file it built from the cells.
create or replace function public.attach_census_file(p_run_id uuid, p_file_path text, p_sha256 text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.census_return_run set file_path = p_file_path, file_sha256 = p_sha256
   where id = p_run_id and tenant_id = app.auth_tenant_id() and status = 'done'
     and (app.auth_role() in ('owner', 'super_admin') or campus_id = any (app.auth_campus_ids()));
  if not found then
    raise exception 'CENSUS_RUN_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.attach_census_file(uuid, text, text) from public, anon;
grant execute on function public.attach_census_file(uuid, text, text) to authenticated;

insert into storage.buckets (id, name, public, file_size_limit)
values ('census-returns', 'census-returns', false, 10485760)
on conflict (id) do update set public = false;
create policy census_returns_read on storage.objects for select to authenticated
  using (bucket_id = 'census-returns' and (storage.foldername(name))[1] = app.auth_tenant_id()::text
         and app.auth_role() in ('owner', 'super_admin', 'principal'));
