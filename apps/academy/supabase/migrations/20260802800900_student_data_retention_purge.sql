-- FR-T16: student data retention and purge policy.
--
-- Personal data of long-departed students is purged on a defined schedule while statutory
-- records stay. The two traps, and how they are handled:
--   * The purge and the statutory register are in direct conflict: a certificate issued in
--     2026 must still be verifiable in 2046 and it names the student. So the register is an
--     explicit carve-out, checked PER ROW against certificate_issue (status = 'issued'), and
--     every exemption is written to the run with its reason.
--   * The job must be idempotent and batched. A run first materialises its candidate list as
--     retention_purge_item rows (unique per run/table/row/category); apply_retention_purge()
--     then works through pending items a batch at a time, each batch one transaction, marking
--     items done as it goes. An interrupted run resumes from the pending items: nothing is
--     processed twice and no purge-log row is duplicated. A dry run writes the same candidate
--     list and counts and modifies nothing.
--
-- Categories (defaults; a tenant may override years per category, Super Admin only):
--   student_identity  null_out      5y after the student's last left_on  B-Form, photo
--   student_name_gr   pseudonymise 10y after left_on                    name, father's name, GR (exempt if a certificate was issued)
--   guardian_contact  null_out      5y after left_on of ALL linked students  CNIC, phones, email
--   fee_ledger        delete         7y after the END of the entry's calendar year  (a 2019 row survives to 2026-12-31)
-- Pseudonyms are one-way (sha256 of tenant, row id and a fixed label). Past audit_log rows are
-- an append-only hash chain and keep what they kept; the purge's own audit rows have the purged
-- values redacted so the purge does not copy the data it removes.
--
-- Platform limits, stated plainly: Supabase storage lifecycle rules cannot be set from SQL, so
-- photo blobs are deleted by the worker from the paths recorded on the purge items; and a
-- purge needs backups, the audit chain and the register to be proven first (hence a monthly
-- dry run on the 1st before live runs on other days).

create index if not exists idx_enrolment_left_on on public.enrolment (left_on) where left_on is not null;

-- ── a transaction-scoped bypass for the two immutability triggers ─────────
create table public.retention_bypass_tx (txid bigint primary key, run_id uuid not null);
alter table public.retention_bypass_tx enable row level security;
revoke all on public.retention_bypass_tx from public, anon, authenticated;

create or replace function app.fn_retention_bypass_active()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.retention_bypass_tx where txid = txid_current());
$$;
revoke execute on function app.fn_retention_bypass_active() from public, anon, authenticated;

create or replace function app.tg_student_gr_number_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.gr_number <> old.gr_number and not app.fn_retention_bypass_active() then
    raise exception 'GR_NUMBER_IMMUTABLE' using errcode = '0A000';
  end if;
  return new;
end;
$$;

create or replace function app.tg_fee_ledger_no_mutate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and app.fn_retention_bypass_active() then
    return old;
  end if;
  raise exception 'FEE_LEDGER_IMMUTABLE' using errcode = '42501';
end;
$$;

-- ── policy, runs, items ───────────────────────────────────────────────────
create table public.retention_policy (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid references public.tenant(id) on delete cascade,   -- null = platform default
  data_category  text not null check (data_category in ('student_identity', 'student_name_gr', 'guardian_contact', 'fee_ledger')),
  retention_years int not null check (retention_years between 1 and 50),
  anchor_event   text not null check (anchor_event in ('left_on', 'created_at', 'issued_at')),
  action         text not null check (action in ('delete', 'pseudonymise', 'null_out')),
  updated_by     uuid references auth.users(id),
  updated_at     timestamptz not null default now()
);
create unique index uq_retention_policy on public.retention_policy (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), data_category);
alter table public.retention_policy enable row level security;
create policy retention_policy_read on public.retention_policy for select to authenticated
  using ((tenant_id is null or tenant_id = app.auth_tenant_id()) and app.auth_role() in ('owner', 'super_admin'));
-- retention_policy_write_super_admin: all writes go through set_retention_policy()

insert into public.retention_policy (tenant_id, data_category, retention_years, anchor_event, action) values
  (null, 'student_identity', 5, 'left_on', 'null_out'),
  (null, 'student_name_gr', 10, 'left_on', 'pseudonymise'),
  (null, 'guardian_contact', 5, 'left_on', 'null_out'),
  (null, 'fee_ledger', 7, 'created_at', 'delete');

create table public.retention_purge_run (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenant(id) on delete cascade,
  as_of            date not null,
  started_at       timestamptz not null default clock_timestamp(),
  finished_at      timestamptz,
  dry_run          boolean not null,
  candidates_count int not null default 0,
  purged_count     int not null default 0,
  exempted_count   int not null default 0,
  status           text not null default 'running' check (status in ('running', 'done', 'failed'))
);
create index idx_retention_run_tenant on public.retention_purge_run (tenant_id, started_at desc);

create table public.retention_purge_item (
  id             uuid primary key default gen_random_uuid(),
  run_id         uuid not null references public.retention_purge_run(id) on delete cascade,
  table_name     text not null,
  row_pk         uuid not null,
  data_category  text not null,
  action_taken   text not null check (action_taken in ('pending', 'dry_run', 'exempt', 'skipped', 'delete', 'pseudonymise', 'null_out')),
  planned_action text not null,
  exemption_reason text,
  storage_bucket text,
  storage_path   text,
  blob_deleted   boolean not null default false,
  processed_at   timestamptz,
  constraint uq_retention_item unique (run_id, table_name, row_pk, data_category)
);
create index idx_retention_item_pending on public.retention_purge_item (run_id) where action_taken = 'pending';

alter table public.retention_purge_run enable row level security;
alter table public.retention_purge_item enable row level security;
-- retention_run_read_owner
create policy retention_run_read_owner on public.retention_purge_run for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin'));
create policy retention_item_read_owner on public.retention_purge_item for select to authenticated
  using (exists (select 1 from public.retention_purge_run r where r.id = run_id));

create or replace function public.set_retention_policy(p_category text, p_years int, p_action text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_def public.retention_policy%rowtype;
begin
  if app.auth_role() <> 'super_admin' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into v_def from public.retention_policy where tenant_id is null and data_category = p_category;
  if not found then
    raise exception 'CATEGORY_UNKNOWN' using errcode = '22023';
  end if;
  if p_years is null or p_years < 1 or p_years > 50 then
    raise exception 'RETENTION_YEARS_INVALID' using errcode = '22023';
  end if;
  insert into public.retention_policy (tenant_id, data_category, retention_years, anchor_event, action, updated_by)
  values (app.auth_tenant_id(), p_category, p_years, v_def.anchor_event, coalesce(p_action, v_def.action), (select auth.uid()))
  on conflict (coalesce(tenant_id, '00000000-0000-0000-0000-000000000000'::uuid), data_category)
  do update set retention_years = excluded.retention_years, action = excluded.action, updated_by = excluded.updated_by, updated_at = now();
end;
$$;
revoke execute on function public.set_retention_policy(text, int, text) from public, anon;
grant execute on function public.set_retention_policy(text, int, text) to authenticated;

create or replace function app.fn_retention_years(p_tenant uuid, p_category text)
returns int
language sql
stable
set search_path = ''
as $$
  select retention_years from public.retention_policy
   where data_category = p_category and (tenant_id = p_tenant or tenant_id is null) order by tenant_id nulls last limit 1;
$$;

-- ── candidates ────────────────────────────────────────────────────────────
create or replace function public.find_retention_candidates(p_tenant uuid, p_as_of date)
returns table (table_name text, row_pk uuid, data_category text, action text, exemption_reason text, storage_bucket text, storage_path text)
language sql
stable
security definer
set search_path = ''
as $$
  with left_students as (
    -- students whose every enrolment has ended; anchor = the last end date
    select s.id, s.photo_path, s.b_form_no, s.gr_number, max(e.left_on) as last_left,
           exists (select 1 from public.certificate_issue c where c.student_id = s.id and c.status = 'issued') as has_issued_cert
      from public.student s
      join public.enrolment e on e.student_id = s.id and e.deleted_at is null
     where s.tenant_id = p_tenant
     group by s.id
    having bool_and(e.left_on is not null and e.left_on <= p_as_of)
  )
  select 'student', ls.id, 'student_identity', 'null_out', null::text,
         case when ls.photo_path is not null then 'student-photos' end, ls.photo_path
    from left_students ls
   where (ls.b_form_no is not null or ls.photo_path is not null)
     and ls.last_left + make_interval(years => app.fn_retention_years(p_tenant, 'student_identity')) <= p_as_of
  union all
  select 'student', ls.id, 'student_name_gr', 'pseudonymise',
         case when ls.has_issued_cert then 'issued_certificate_register' end, null, null
    from left_students ls
   where ls.gr_number not like 'PSEUDO-%'
     and ls.last_left + make_interval(years => app.fn_retention_years(p_tenant, 'student_name_gr')) <= p_as_of
  union all
  select 'guardian', g.id, 'guardian_contact', 'null_out', null, null, null
    from public.guardian g
   where g.tenant_id = p_tenant
     and (g.cnic is not null or g.phone_e164 is not null or g.alt_phone is not null or g.email is not null)
     and exists (select 1 from public.student_guardian sg where sg.guardian_id = g.id)
     and not exists (
       -- a guardian keeps their contact data while ANY linked child is still enrolled or recently left
       select 1 from public.student_guardian sg
        where sg.guardian_id = g.id
          and not exists (
            select 1 from left_students ls
             where ls.id = sg.student_id
               and ls.last_left + make_interval(years => app.fn_retention_years(p_tenant, 'guardian_contact')) <= p_as_of))
  union all
  select 'fee_ledger', l.id, 'fee_ledger', 'delete', null, null, null
    from public.fee_ledger l
   where l.tenant_id = p_tenant
     and (date_trunc('year', l.value_date) + interval '1 year' - interval '1 day')::date + make_interval(years => app.fn_retention_years(p_tenant, 'fee_ledger')) < p_as_of;
$$;
revoke execute on function public.find_retention_candidates(uuid, date) from public, anon, authenticated;
grant execute on function public.find_retention_candidates(uuid, date) to service_role;

-- Starts a run: materialises the candidate list. A dry run ends here.
create or replace function app.fn_start_retention_run(p_tenant uuid, p_as_of date, p_dry_run boolean)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  insert into public.retention_purge_run (tenant_id, as_of, dry_run) values (p_tenant, p_as_of, p_dry_run) returning id into v_id;
  insert into public.retention_purge_item (run_id, table_name, row_pk, data_category, action_taken, planned_action, exemption_reason, storage_bucket, storage_path)
  select v_id, c.table_name, c.row_pk, c.data_category,
         case when c.exemption_reason is not null then 'exempt' when p_dry_run then 'dry_run' else 'pending' end,
         c.action, c.exemption_reason, c.storage_bucket, c.storage_path
    from public.find_retention_candidates(p_tenant, p_as_of) c
  on conflict do nothing;
  update public.retention_purge_run r
     set candidates_count = (select count(*) from public.retention_purge_item i where i.run_id = v_id),
         exempted_count = (select count(*) from public.retention_purge_item i where i.run_id = v_id and i.action_taken = 'exempt'),
         status = case when p_dry_run or not exists (select 1 from public.retention_purge_item i where i.run_id = v_id and i.action_taken = 'pending') then 'done' else 'running' end,
         finished_at = case when p_dry_run or not exists (select 1 from public.retention_purge_item i where i.run_id = v_id and i.action_taken = 'pending') then clock_timestamp() end
   where r.id = v_id;
  return v_id;
end;
$$;
revoke execute on function app.fn_start_retention_run(uuid, date, boolean) from public, anon, authenticated;

create or replace function public.start_retention_run(p_dry_run boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() <> 'super_admin' then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_start_retention_run(app.auth_tenant_id(), app.fn_karachi_today(), p_dry_run);
end;
$$;
revoke execute on function public.start_retention_run(boolean) from public, anon;
grant execute on function public.start_retention_run(boolean) to authenticated;

-- ── applying: batched, idempotent, resumable ──────────────────────────────
create or replace function public.apply_retention_purge(p_run_id uuid, p_batch_size int default 500)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  r        public.retention_purge_run%rowtype;
  it       record;
  v_done   int := 0;
  v_added  text[];
  v_pending int;
begin
  select * into r from public.retention_purge_run where id = p_run_id and status = 'running' and not dry_run for update;
  if not found then
    return 0;
  end if;

  insert into public.retention_bypass_tx (txid, run_id) values (txid_current(), p_run_id) on conflict do nothing;
  -- keep the removed values out of the purge's own audit rows
  with ins as (
    insert into public.audit_redacted_column (table_name, column_name)
    select t, c from (values
      ('student','b_form_no'),('student','bform_digits'),('student','photo_path'),('student','name_en'),('student','name_ur'),('student','name_ur_roman'),
      ('student','father_name_en'),('student','father_name_ur'),('student','gr_number'),('student','gr_digits'),
      ('guardian','cnic'),('guardian','cnic_digits'),('guardian','phone_e164'),('guardian','alt_phone'),('guardian','phone_last10'),('guardian','alt_phone_last10'),('guardian','email')
    ) v(t, c)
    on conflict do nothing returning table_name || '.' || column_name)
  select coalesce(array_agg(x), '{}') into v_added from ins x(x);

  for it in
    select * from public.retention_purge_item where run_id = p_run_id and action_taken = 'pending'
     order by id for update skip locked limit greatest(p_batch_size, 1)
  loop
    if it.data_category = 'student_identity' then
      update public.student set b_form_no = null, photo_path = null where id = it.row_pk and tenant_id = r.tenant_id;
    elsif it.data_category = 'student_name_gr' then
      update public.student set
        name_en = 'PSEUDO-' || substr(encode(extensions.digest(r.tenant_id::text || it.row_pk::text || 'name', 'sha256'), 'hex'), 1, 10),
        name_ur = null, father_name_en = null, father_name_ur = null,
        gr_number = 'PSEUDO-' || substr(encode(extensions.digest(r.tenant_id::text || it.row_pk::text || 'gr', 'sha256'), 'hex'), 1, 10)
       where id = it.row_pk and tenant_id = r.tenant_id;
    elsif it.data_category = 'guardian_contact' then
      update public.guardian set cnic = null, phone_e164 = null, alt_phone = null, email = null where id = it.row_pk and tenant_id = r.tenant_id;
    elsif it.data_category = 'fee_ledger' then
      delete from public.fee_ledger where id = it.row_pk and tenant_id = r.tenant_id;
    end if;
    update public.retention_purge_item set action_taken = planned_action, processed_at = clock_timestamp() where id = it.id;
    v_done := v_done + 1;
  end loop;

  delete from public.audit_redacted_column where table_name || '.' || column_name = any (v_added);
  delete from public.retention_bypass_tx where txid = txid_current();

  update public.retention_purge_run set purged_count = purged_count + v_done where id = p_run_id;
  select count(*) into v_pending from public.retention_purge_item where run_id = p_run_id and action_taken = 'pending';
  if v_pending = 0 then
    update public.retention_purge_run set status = 'done', finished_at = clock_timestamp() where id = p_run_id;
  end if;
  return v_pending;
end;
$$;
revoke execute on function public.apply_retention_purge(uuid, int) from public, anon, authenticated;
grant execute on function public.apply_retention_purge(uuid, int) to service_role;

-- 03:30 Asia/Karachi: every tenant, live runs except the 1st of the month, which is a dry run.
create or replace function public.retention_purge_nightly(p_time_budget interval default interval '20 minutes')
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  t       record;
  v_run   uuid;
  v_left  int;
  v_start timestamptz := clock_timestamp();
  v_n     int := 0;
begin
  for t in select id from public.tenant loop
    -- resume an unfinished live run before starting a new one
    select id into v_run from public.retention_purge_run where tenant_id = t.id and status = 'running' and not dry_run order by started_at limit 1;
    if v_run is null then
      v_run := app.fn_start_retention_run(t.id, app.fn_karachi_today(), extract(day from app.fn_karachi_today()) = 1);
    end if;
    loop
      v_left := public.apply_retention_purge(v_run, 500);
      exit when v_left = 0 or clock_timestamp() - v_start > p_time_budget;
    end loop;
    v_n := v_n + 1;
    exit when clock_timestamp() - v_start > p_time_budget;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.retention_purge_nightly(interval) from public, anon, authenticated;
grant execute on function public.retention_purge_nightly(interval) to service_role;

-- Blob cleanup for photos named on purge items (storage lifecycle rules cannot be set from SQL).
create or replace function public.retention_blobs_to_delete(p_limit int default 200)
returns table (item_id uuid, storage_bucket text, storage_path text)
language sql
security definer
set search_path = ''
as $$
  select id, storage_bucket, storage_path from public.retention_purge_item
   where storage_path is not null and not blob_deleted and action_taken = 'null_out' order by processed_at limit least(p_limit, 1000);
$$;
revoke execute on function public.retention_blobs_to_delete(int) from public, anon, authenticated;
grant execute on function public.retention_blobs_to_delete(int) to service_role;

create or replace function public.mark_retention_blob_deleted(p_item_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.retention_purge_item set blob_deleted = true where id = p_item_id;
$$;
revoke execute on function public.mark_retention_blob_deleted(uuid) from public, anon, authenticated;
grant execute on function public.mark_retention_blob_deleted(uuid) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- 03:30 Asia/Karachi = 22:30 UTC
    perform cron.schedule('retention-purge', '30 22 * * *', 'select public.retention_purge_nightly();');
  end if;
exception
  when others then null;
end;
$$;
