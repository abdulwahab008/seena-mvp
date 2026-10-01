-- FR-Q04: hostel visitor entry and exit log.
--
-- Gate staff log every visitor in and out. A CNIC that matches a guardian of the
-- student being visited pre-fills the relationship and flags the visit verified;
-- anything else is unverified and highlighted. A visit still open at the hostel's
-- closing time (tenant setting hostel.visiting_close, default 21:00 PKT) is alerted
-- to the warden by the daily 21:05 PKT job, once.
--
-- A visitor is a person who is not a user of the system, so the log is on a short
-- retention clock (tenant setting hostel.visitor_retention_days, default 180).
-- The nightly purge deletes expired rows and queues their photographs on
-- storage_delete_queue, the existing purge job's queue. Name, CNIC, phone and photo
-- path are redacted from audit_log so the audit trail does not become a second,
-- permanent copy of strangers' identity data. The photograph lives in the private
-- bucket hostel-visitor-photos (path tenant_id/campus_id/visit_id.ext), readable
-- only by hostel and gate staff, never by a parent or student account.

create table public.hostel_visitor_log (
  id                 uuid primary key default gen_random_uuid(),
  tenant_id          uuid not null references public.tenant(id) on delete cascade,
  campus_id          uuid not null references public.campus(id) on delete cascade,
  student_id         uuid not null references public.student(id),
  visitor_name       text not null check (char_length(btrim(visitor_name)) between 2 and 120),
  visitor_cnic       text not null check (visitor_cnic ~ '^[0-9]{5}-[0-9]{7}-[0-9]$'),
  relationship       text check (relationship is null or char_length(relationship) <= 60),
  phone              text check (phone is null or char_length(phone) <= 20),
  entered_at         timestamptz not null default now(),
  exited_at          timestamptz,
  verified           boolean not null default false,
  photo_path         text,
  recorded_by        uuid references auth.users(id),
  closing_alerted_at timestamptz,
  constraint chk_visit_times check (exited_at is null or exited_at >= entered_at)
);
create index idx_open_visits on public.hostel_visitor_log (campus_id, entered_at desc) where exited_at is null;
create index idx_visitor_scope on public.hostel_visitor_log (tenant_id, campus_id, entered_at desc);
create index idx_visitor_student on public.hostel_visitor_log (student_id);

insert into public.audit_redacted_column (table_name, column_name) values
  ('hostel_visitor_log', 'visitor_name'), ('hostel_visitor_log', 'visitor_cnic'), ('hostel_visitor_log', 'phone'), ('hostel_visitor_log', 'photo_path')
on conflict do nothing;
create trigger hostel_visitor_log_audit after insert or update or delete on public.hostel_visitor_log
  for each row execute function app.tg_audit_row();

-- Hostel staff and the gate (receptionist) of the campus. Never parents or students.
create or replace function app.fn_visitor_staff(p_tenant uuid, p_campus uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_hostel_staff(p_tenant, p_campus)
      or (p_tenant = app.auth_tenant_id() and app.auth_role() = 'receptionist' and p_campus = any (app.auth_campus_ids()));
$$;
revoke execute on function app.fn_visitor_staff(uuid, uuid) from public, anon;
grant execute on function app.fn_visitor_staff(uuid, uuid) to authenticated;

alter table public.hostel_visitor_log enable row level security;
create policy hostel_visitor_campus_scope on public.hostel_visitor_log for select to authenticated
  using (app.fn_visitor_staff(tenant_id, campus_id));

create view public.v_hostel_open_visits with (security_invoker = true) as
select v.id, v.tenant_id, v.campus_id, v.student_id, st.name_en as student_name, st.gr_number, v.visitor_name, v.visitor_cnic,
       v.relationship, v.phone, v.entered_at, v.verified, v.photo_path
  from public.hostel_visitor_log v join public.student st on st.id = v.student_id
 where v.exited_at is null
 order by v.entered_at desc;
revoke all on public.v_hostel_open_visits from anon;
grant select on public.v_hostel_open_visits to authenticated;

-- ── Bucket ──────────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hostel-visitor-photos', 'hostel-visitor-photos', false, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set file_size_limit = 3145728, allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

create policy hostel_visitor_photo_read on storage.objects for select to authenticated
  using (bucket_id = 'hostel-visitor-photos'
         and (storage.foldername(name))[1] = app.auth_tenant_id()::text
         and (storage.foldername(name))[2] ~ '^[0-9a-f-]{36}$'
         and app.fn_visitor_staff(((storage.foldername(name))[1])::uuid, ((storage.foldername(name))[2])::uuid));
create policy hostel_visitor_photo_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'hostel-visitor-photos'
              and (storage.foldername(name))[1] = app.auth_tenant_id()::text
              and (storage.foldername(name))[2] ~ '^[0-9a-f-]{36}$'
              and app.fn_visitor_staff(((storage.foldername(name))[1])::uuid, ((storage.foldername(name))[2])::uuid));

-- ── Entry and exit ──────────────────────────────────────────────────────────
-- p_visit_id lets the browser upload the photograph first at tenant/campus/visit_id.ext.
create or replace function public.log_hostel_visit(
  p_student_id uuid, p_visitor_name text, p_visitor_cnic text, p_relationship text default null, p_phone text default null,
  p_photo_path text default null, p_visit_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_stud   public.student%rowtype;
  v_digits text := regexp_replace(coalesce(p_visitor_cnic, ''), '\D', '', 'g');
  v_cnic   text;
  v_rel    text;
  v_verified boolean := false;
  v_id     uuid := coalesce(p_visit_id, gen_random_uuid());
begin
  select * into v_stud from public.student where id = p_student_id and tenant_id = app.auth_tenant_id() and deleted_at is null;
  if not found then
    raise exception 'STUDENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_visitor_staff(v_stud.tenant_id, v_stud.campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(v_digits) <> 13 then
    raise exception 'CNIC_INVALID' using errcode = '22023';
  end if;
  v_cnic := substr(v_digits, 1, 5) || '-' || substr(v_digits, 6, 7) || '-' || substr(v_digits, 13, 1);
  if p_photo_path is not null and p_photo_path not like v_stud.tenant_id::text || '/' || v_stud.campus_id::text || '/' || v_id::text || '%' then
    raise exception 'PHOTO_PATH_INVALID' using errcode = '22023';
  end if;
  select sg.relationship::text into v_rel
    from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
   where sg.student_id = p_student_id and sg.to_date is null and g.cnic_digits = v_digits
   limit 1;
  if found then
    v_verified := true;
  else
    v_rel := nullif(btrim(p_relationship), '');
  end if;
  insert into public.hostel_visitor_log (id, tenant_id, campus_id, student_id, visitor_name, visitor_cnic, relationship, phone, verified, photo_path, recorded_by)
  values (v_id, v_stud.tenant_id, v_stud.campus_id, p_student_id, btrim(p_visitor_name), v_cnic, v_rel, nullif(btrim(p_phone), ''), v_verified, p_photo_path, (select auth.uid()));
  return jsonb_build_object('id', v_id, 'verified', v_verified, 'relationship', v_rel);
end;
$$;
revoke execute on function public.log_hostel_visit(uuid, text, text, text, text, text, uuid) from public, anon;
grant execute on function public.log_hostel_visit(uuid, text, text, text, text, text, uuid) to authenticated;

-- Tells the gate form who a CNIC is before the entry is saved.
create or replace function public.lookup_visitor_relationship(p_student_id uuid, p_visitor_cnic text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select sg.relationship::text
    from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id join public.student s on s.id = sg.student_id
   where sg.student_id = p_student_id and s.tenant_id = app.auth_tenant_id() and sg.to_date is null
     and g.cnic_digits = regexp_replace(coalesce(p_visitor_cnic, ''), '\D', '', 'g')
     and app.fn_visitor_staff(s.tenant_id, s.campus_id)
   limit 1;
$$;
revoke execute on function public.lookup_visitor_relationship(uuid, text) from public, anon;
grant execute on function public.lookup_visitor_relationship(uuid, text) to authenticated;

create or replace function public.exit_hostel_visit(p_visit_id uuid, p_exited_at timestamptz default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_v public.hostel_visitor_log%rowtype;
begin
  select * into v_v from public.hostel_visitor_log where id = p_visit_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'VISIT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not app.fn_visitor_staff(v_v.tenant_id, v_v.campus_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_v.exited_at is not null then
    raise exception 'VISIT_ALREADY_CLOSED' using errcode = '22023';
  end if;
  update public.hostel_visitor_log set exited_at = greatest(coalesce(p_exited_at, now()), entered_at) where id = p_visit_id;
end;
$$;
revoke execute on function public.exit_hostel_visit(uuid, timestamptz) from public, anon;
grant execute on function public.exit_hostel_visit(uuid, timestamptz) to authenticated;

-- ── Closing-time check (daily 16:05 UTC = 21:05 PKT) ────────────────────────
create or replace function public.hostel_open_visit_check(p_now timestamptz default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  r     record;
  v_close time;
  v_n   int := 0;
begin
  for r in
    select v.id, v.tenant_id, v.campus_id, v.visitor_name, v.entered_at, st.name_en, st.gr_number
      from public.hostel_visitor_log v join public.student st on st.id = v.student_id
     where v.exited_at is null and v.closing_alerted_at is null
     for update of v skip locked
  loop
    v_close := coalesce((app.fn_transport_setting(r.tenant_id, 'hostel.visiting_close', '"21:00"'::jsonb) #>> '{}')::time, time '21:00');
    if v_now < (((r.entered_at at time zone 'Asia/Karachi')::date + v_close) at time zone 'Asia/Karachi') then
      continue;
    end if;
    update public.hostel_visitor_log set closing_alerted_at = v_now where id = r.id;
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    select distinct r.tenant_id, uid, 'hostel_visitor_inside', 'Visitor still inside: ' || r.visitor_name,
           r.visitor_name || ' (visiting ' || r.name_en || ', GR ' || r.gr_number || ') entered at ' || to_char(r.entered_at at time zone 'Asia/Karachi', 'HH24:MI') || ' and has not signed out after closing time ' || to_char(v_close, 'HH24:MI') || '.',
           '/hostel/visitors'
      from (
        select s.user_id as uid from public.hostel_block b join public.staff s on s.id = b.warden_staff_id
         where b.tenant_id = r.tenant_id and b.campus_id = r.campus_id and s.user_id is not null
        union
        select au.user_id from public.app_user au join public.user_campus uc on uc.user_id = au.user_id and uc.campus_id = r.campus_id
         where au.tenant_id = r.tenant_id and au.app_role = 'principal' and au.status = 'active'
      ) w;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.hostel_open_visit_check(timestamptz) from public, anon, authenticated;
grant execute on function public.hostel_open_visit_check(timestamptz) to service_role;

-- ── Retention (nightly) ─────────────────────────────────────────────────────
create or replace function public.hostel_visitor_retention_purge(p_now timestamptz default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_now timestamptz := coalesce(p_now, now());
  v_n   int;
begin
  insert into public.storage_delete_queue (bucket, path)
  select 'hostel-visitor-photos', v.photo_path
    from public.hostel_visitor_log v
   where v.photo_path is not null
     and v.entered_at < v_now - make_interval(days => coalesce((app.fn_transport_setting(v.tenant_id, 'hostel.visitor_retention_days', '180'::jsonb))::text::int, 180))
  on conflict do nothing;
  delete from public.hostel_visitor_log v
   where v.entered_at < v_now - make_interval(days => coalesce((app.fn_transport_setting(v.tenant_id, 'hostel.visitor_retention_days', '180'::jsonb))::text::int, 180));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.hostel_visitor_retention_purge(timestamptz) from public, anon, authenticated;
grant execute on function public.hostel_visitor_retention_purge(timestamptz) to service_role;

-- Tenant settings for the two clocks (and the mess-off notice period of FR-Q05).
create or replace function public.set_hostel_setting(p_key text, p_value jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_key = 'hostel.visiting_close' and (jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key = 'hostel.visitor_retention_days' and (jsonb_typeof(p_value) <> 'number' or (p_value)::text::numeric < 7 or (p_value)::text::numeric > 3650 or (p_value)::text::numeric <> trunc((p_value)::text::numeric)) then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key = 'hostel.mess_notice_hours' and (jsonb_typeof(p_value) <> 'number' or (p_value)::text::numeric < 0 or (p_value)::text::numeric > 720 or (p_value)::text::numeric <> trunc((p_value)::text::numeric)) then
    raise exception 'SETTING_INVALID' using errcode = '22023';
  elsif p_key not in ('hostel.visiting_close', 'hostel.visitor_retention_days', 'hostel.mess_notice_hours') then
    raise exception 'SETTING_UNKNOWN' using errcode = '22023';
  end if;
  insert into public.tenant_setting (tenant_id, key, value) values (app.auth_tenant_id(), p_key, p_value)
  on conflict (tenant_id, key) do update set value = excluded.value;
end;
$$;
revoke execute on function public.set_hostel_setting(text, jsonb) from public, anon;
grant execute on function public.set_hostel_setting(text, jsonb) to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('hostel_open_visit_check', '5 16 * * *', 'select public.hostel_open_visit_check();');
    perform cron.schedule('hostel_visitor_retention_purge', '30 21 * * *', 'select public.hostel_visitor_retention_purge();');
  end if;
exception
  when others then null;
end;
$$;
