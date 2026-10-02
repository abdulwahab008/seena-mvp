-- FR-G16: attendance shortage warning generation.
--
-- Weekly, for every active enrolment of a campus whose policy sets
-- min_attendance_pct: session-to-date attendance (present and late count 1,
-- half_day 0.5, absent and excused 0, over the days actually recorded, the
-- same weighting as the monthly summary). Below the threshold a level-1
-- warning is raised; at each later evaluation the SAME open warning escalates
-- to 2 and then 3 (a partial unique index guarantees one open warning per
-- enrolment, so a parent never gets the same alarm eight weeks running);
-- back above the threshold it is closed as 'recovered'. Under 20 recorded
-- days nothing is raised: a fortnight of data is not a sample. An escalation
-- needs six days since the last one, so a manual run beside the schedule
-- cannot jump a student from level 1 to 3 in an afternoon.
--
-- Each raise queues an SMS to the primary academic guardian (English or
-- Urdu, quiet hours respected, idempotent per warning and level); level 3 also
-- notifies the campus Principal in-app.

create table public.attendance_shortage_warning (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  session_id        uuid not null references public.academic_session(id) on delete cascade,
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  level             smallint not null check (level between 1 and 3),
  pct_at_warning    numeric(5, 2) not null,
  raised_at         timestamptz not null default now(),
  last_escalated_at timestamptz not null default now(),
  status            text not null default 'open' check (status in ('open', 'recovered', 'closed')),
  closed_at         timestamptz,
  closed_reason     text,
  closed_by         uuid references auth.users(id),
  constraint shortage_closed_has_time check ((status = 'open') = (closed_at is null))
);
create unique index uq_open_shortage on public.attendance_shortage_warning (enrolment_id) where status = 'open';
create index idx_shortage_scope on public.attendance_shortage_warning (tenant_id, campus_id, status);
create index idx_shortage_session on public.attendance_shortage_warning (session_id);

create trigger attendance_shortage_warning_audit after insert or update or delete on public.attendance_shortage_warning
  for each row execute function app.tg_audit_row();

alter table public.attendance_shortage_warning enable row level security;
create policy shortage_campus_read on public.attendance_shortage_warning for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and app.auth_role() in ('owner', 'super_admin', 'principal', 'vice_principal', 'class_teacher', 'exam_controller')
    and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()))
  );

create or replace function app.fn_ensure_shortage_templates(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text;
  v_t    uuid;
  v_en   text;
  v_ur   text;
begin
  foreach v_code in array array['attendance_shortage_l1', 'attendance_shortage_l2', 'attendance_shortage_l3'] loop
    insert into public.message_template (tenant_id, code, channel, name, audience_entity, category)
    values (p_tenant_id, v_code, 'sms', 'Attendance shortage ' || right(v_code, 2), 'guardian', 'attendance') on conflict do nothing;
    select id into v_t from public.message_template where tenant_id = p_tenant_id and code = v_code;
    if not exists (select 1 from public.message_template_version where template_id = v_t) then
      v_en := case right(v_code, 2)
        when 'l1' then 'Dear {{guardian_name}}, {{student_name}} attendance is {{pct}}%, below the required {{min_pct}}%. Please ensure regular attendance.'
        when 'l2' then 'Dear {{guardian_name}}, second notice: {{student_name}} attendance is still {{pct}}%, below the required {{min_pct}}%. Exam eligibility is at risk.'
        else 'Dear {{guardian_name}}, FINAL notice: {{student_name}} attendance is {{pct}}%, below the required {{min_pct}}%. Please contact the school immediately.' end;
      v_ur := case right(v_code, 2)
        when 'l1' then 'محترم {{guardian_name}}، {{student_name}} کی حاضری {{pct}}% ہے جو مطلوبہ {{min_pct}}% سے کم ہے۔ براہ کرم باقاعدہ حاضری یقینی بنائیں۔'
        when 'l2' then 'محترم {{guardian_name}}، دوسرا نوٹس: {{student_name}} کی حاضری اب بھی {{pct}}% ہے جو مطلوبہ {{min_pct}}% سے کم ہے۔ امتحان کی اہلیت خطرے میں ہے۔'
        else 'محترم {{guardian_name}}، آخری نوٹس: {{student_name}} کی حاضری {{pct}}% ہے جو مطلوبہ {{min_pct}}% سے کم ہے۔ براہ کرم فوراً اسکول سے رابطہ کریں۔' end;
      insert into public.message_template_version (template_id, version_no, message_class, body_en, body_ur, is_published, published_at)
      values (v_t, 1, 'reminder', v_en, v_ur, true, now());
    end if;
  end loop;
end;
$$;
revoke execute on function app.fn_ensure_shortage_templates(uuid) from public, anon, authenticated;

create or replace function app.fn_notify_shortage(p_warning_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  w       public.attendance_shortage_warning%rowtype;
  v_name  text;
  v_min   numeric;
  v_g     record;
  v_ver   uuid;
  v_body  text;
  v_sched timestamptz;
  v_now   timestamptz := now();
begin
  select * into w from public.attendance_shortage_warning where id = p_warning_id;
  select st.name_en into v_name from public.enrolment e join public.student st on st.id = e.student_id where e.id = w.enrolment_id;
  select (app.resolve_attendance_policy_unscoped(w.tenant_id, w.campus_id, w.session_id) ->> 'min_attendance_pct')::numeric into v_min;

  perform app.fn_ensure_shortage_templates(w.tenant_id);
  select g.id as guardian_id, g.name_en, g.phone_e164, g.preferred_language
    into v_g
    from public.enrolment e
    join public.student_guardian sg on sg.student_id = e.student_id and sg.to_date is null and sg.receives_academic
    join public.guardian g on g.id = sg.guardian_id and g.phone_e164 is not null
   where e.id = w.enrolment_id
   order by sg.is_primary desc, sg.priority asc
   limit 1;

  if v_g.guardian_id is not null then
    select v.id into v_ver from public.message_template t join public.message_template_version v on v.template_id = t.id
     where t.tenant_id = w.tenant_id and t.code = 'attendance_shortage_l' || w.level and v.is_published order by v.version_no desc limit 1;
    v_body := public.render_template(v_ver, jsonb_build_object('guardian_name', v_g.name_en, 'student_name', v_name, 'pct', trim_scale(w.pct_at_warning)::text, 'min_pct', trim_scale(v_min)::text), coalesce(v_g.preferred_language, 'en'));
    v_sched := case when public.is_quiet_now(w.tenant_id, v_now) then public.get_next_quiet_window_end(w.tenant_id, v_now) else v_now end;
    insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, status, scheduled_at, idempotency_key, template_version_id, message_class, metadata)
    values (w.tenant_id, w.campus_id, 'guardian', v_g.guardian_id, v_g.phone_e164, 'sms', v_body, 'queued', v_sched,
            'shortage:' || w.id || ':' || w.level, v_ver, 'reminder', jsonb_build_object('warning_id', w.id, 'level', w.level))
    on conflict do nothing;
  end if;

  if w.level = 3 then
    insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
    select w.tenant_id, au.user_id, 'attendance_shortage_l3', 'Level 3 attendance shortage: ' || v_name,
           v_name || ' is at ' || trim_scale(w.pct_at_warning)::text || '% against the required ' || trim_scale(v_min)::text || '%.', '/attendance/shortage'
      from public.app_user au
      join public.user_campus uc on uc.user_id = au.user_id and uc.campus_id = w.campus_id
     where au.tenant_id = w.tenant_id and au.app_role = 'principal' and au.status = 'active';
  end if;
end;
$$;
revoke execute on function app.fn_notify_shortage(uuid) from public, anon, authenticated;

create or replace function public.evaluate_attendance_shortage(p_campus_id uuid, p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant  uuid;
  v_ses     public.academic_session%rowtype;
  v_min     numeric;
  r         record;
  v_open    public.attendance_shortage_warning%rowtype;
  v_id      uuid;
  v_raised  int := 0;
  v_escal   int := 0;
  v_recov   int := 0;
  v_skipped int := 0;
begin
  select tenant_id into v_tenant from public.campus where id = p_campus_id;
  if v_tenant is null then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_tenant_id() is not null then
    if v_tenant <> app.auth_tenant_id() then
      raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
    end if;
    if app.auth_role() not in ('owner', 'super_admin', 'principal', 'exam_controller') then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
    if app.auth_role() not in ('owner', 'super_admin') and not (p_campus_id = any(app.auth_campus_ids())) then
      raise exception 'FORBIDDEN' using errcode = '42501';
    end if;
  end if;
  select * into v_ses from public.academic_session where id = p_session_id and tenant_id = v_tenant;
  if not found then
    raise exception 'SESSION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select (app.resolve_attendance_policy_unscoped(v_tenant, p_campus_id, p_session_id) ->> 'min_attendance_pct')::numeric into v_min;
  if v_min is null then
    return jsonb_build_object('raised', 0, 'escalated', 0, 'recovered', 0, 'skipped', 0, 'threshold', null);
  end if;

  for r in
    select e.id as enrolment_id, count(a.id) as recorded,
           coalesce(sum(case a.status when 'present' then 1 when 'late' then 1 when 'half_day' then 0.5 else 0 end), 0) as attended
      from public.enrolment e
      left join public.attendance_day a on a.enrolment_id = e.id and a.attendance_date between v_ses.starts_on and least(v_ses.ends_on, app.fn_karachi_today())
     where e.campus_id = p_campus_id and e.session_id = p_session_id and e.status = 'active' and e.deleted_at is null
     group by e.id
  loop
    select * into v_open from public.attendance_shortage_warning where enrolment_id = r.enrolment_id and status = 'open';
    if r.recorded < 20 then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    declare
      v_pct numeric(5, 2) := round(100.0 * r.attended / r.recorded, 2);
    begin
      if v_pct >= v_min then
        if v_open.id is not null then
          update public.attendance_shortage_warning set status = 'recovered', closed_at = now(), closed_reason = 'recovered' where id = v_open.id;
          v_recov := v_recov + 1;
        end if;
      elsif v_open.id is null then
        insert into public.attendance_shortage_warning (tenant_id, campus_id, session_id, enrolment_id, level, pct_at_warning)
        values (v_tenant, p_campus_id, p_session_id, r.enrolment_id, 1, v_pct) returning id into v_id;
        perform app.fn_notify_shortage(v_id);
        v_raised := v_raised + 1;
      elsif v_open.level < 3 and v_open.last_escalated_at <= now() - interval '6 days' then
        update public.attendance_shortage_warning
           set level = level + 1, pct_at_warning = v_pct, last_escalated_at = now()
         where id = v_open.id;
        perform app.fn_notify_shortage(v_open.id);
        v_escal := v_escal + 1;
      end if;
    end;
  end loop;
  return jsonb_build_object('raised', v_raised, 'escalated', v_escal, 'recovered', v_recov, 'skipped', v_skipped, 'threshold', v_min);
end;
$$;
revoke execute on function public.evaluate_attendance_shortage(uuid, uuid) from public, anon;
grant execute on function public.evaluate_attendance_shortage(uuid, uuid) to authenticated, service_role;

create or replace function public.evaluate_attendance_shortage_all()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  c   record;
  v_n int := 0;
begin
  for c in
    select ca.id as campus_id, s.id as session_id
      from public.campus ca
      join public.academic_session s on s.tenant_id = ca.tenant_id and (s.campus_id is null or s.campus_id = ca.id) and s.status = 'active'
     where ca.status = 'active'
  loop
    perform public.evaluate_attendance_shortage(c.campus_id, c.session_id);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke execute on function public.evaluate_attendance_shortage_all() from public, anon, authenticated;
grant execute on function public.evaluate_attendance_shortage_all() to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('shortage_eval', '0 13 * * 6', 'select public.evaluate_attendance_shortage_all();');
  end if;
exception
  when others then null;
end;
$$;

create or replace function public.close_shortage_warning(p_warning_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'class_teacher') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) < 10 then
    raise exception 'REASON_MIN_LENGTH_10' using errcode = '23514';
  end if;
  update public.attendance_shortage_warning
     set status = 'closed', closed_at = now(), closed_reason = btrim(p_reason), closed_by = (select auth.uid())
   where id = p_warning_id and tenant_id = app.auth_tenant_id() and status = 'open'
     and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids()));
  if not found then
    raise exception 'WARNING_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.close_shortage_warning(uuid, text) from public, anon;
grant execute on function public.close_shortage_warning(uuid, text) to authenticated;
