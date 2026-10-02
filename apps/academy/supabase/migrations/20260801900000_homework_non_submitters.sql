-- FR-H07: non-submission list and follow-up.
--
-- For a homework the teacher owns (or shares by section and subject), lists the
-- enrolled students with no submission in 'submitted' or 'checked' status (a
-- half-finished draft is still a non-submission). A student on approved leave
-- for the whole assignment window is flagged and left out of the default
-- selection, because a scolding SMS about work a hospitalised child could not
-- do is the failure this guards against. The list is available before the due
-- date as information only: notify_non_submitters() refuses until the day
-- after the due date.
--
-- Dispatch queues one SMS per primary guardian, once per student per day
-- (unique on homework, enrolment, channel and day), counted against a per
-- campus daily cap so homework reminders cannot eat the tenant's SMS budget.
-- They are scheduled after a short delay so absentee alerts, queued
-- immediately, leave the outbox first. Guardian contact details are returned
-- only to a teacher of that homework, through this function.

create table public.homework_notification_policy (
  tenant_id            uuid primary key references public.tenant(id) on delete cascade,
  daily_cap_per_campus int not null default 100 check (daily_cap_per_campus between 0 and 5000)
);
alter table public.homework_notification_policy enable row level security;
create policy homework_notification_policy_read on public.homework_notification_policy for select to authenticated
  using (tenant_id = app.auth_tenant_id());

create or replace function public.set_homework_notification_cap(p_cap int)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_cap is null or p_cap < 0 or p_cap > 5000 then
    raise exception 'CAP_OUT_OF_RANGE' using errcode = '22023';
  end if;
  insert into public.homework_notification_policy (tenant_id, daily_cap_per_campus) values (app.auth_tenant_id(), p_cap)
  on conflict (tenant_id) do update set daily_cap_per_campus = excluded.daily_cap_per_campus;
end;
$$;
revoke execute on function public.set_homework_notification_cap(int) from public, anon;
grant execute on function public.set_homework_notification_cap(int) to authenticated;

create table public.homework_notification (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenant(id) on delete cascade,
  campus_id           uuid not null references public.campus(id) on delete cascade,
  homework_id         uuid not null references public.homework(id) on delete cascade,
  enrolment_id        uuid not null references public.enrolment(id) on delete cascade,
  channel             text not null default 'sms',
  status              text not null check (status in ('queued', 'skipped_no_phone')),
  message_id          uuid references public.message(id) on delete set null,
  sent_on             date not null default app.fn_karachi_today(),
  created_by          uuid references auth.users(id),
  sent_at             timestamptz not null default now(),
  constraint uq_homework_notification_day unique (homework_id, enrolment_id, channel, sent_on)
);
create index idx_hw_notification_campus_day on public.homework_notification (tenant_id, campus_id, sent_on);
create index idx_hw_notification_enrolment on public.homework_notification (enrolment_id);
create index idx_hw_notification_message on public.homework_notification (message_id);
alter table public.homework_notification enable row level security;
create policy homework_notification_read on public.homework_notification for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.fn_teacher_of_homework(homework_id));

create or replace function public.homework_non_submitters(p_homework_id uuid)
returns table (enrolment_id uuid, student_name text, gr_number text, guardian_name text, guardian_phone text, on_leave boolean, notified_today boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_hw public.homework%rowtype;
begin
  select * into v_hw from public.homework where id = p_homework_id and tenant_id = app.auth_tenant_id() and status = 'published';
  if not found or not app.fn_teacher_of_homework(p_homework_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
  select e.id, st.name_en, st.gr_number, g.name_en, g.phone_e164,
         exists (select 1 from public.student_leave_application l
                  where l.enrolment_id = e.id and l.status = 'approved' and l.from_date <= v_hw.assigned_date and l.to_date >= v_hw.due_date),
         exists (select 1 from public.homework_notification n where n.homework_id = p_homework_id and n.enrolment_id = e.id and n.sent_on = app.fn_karachi_today())
    from public.enrolment e
    join public.student st on st.id = e.student_id
    left join lateral (
      select gu.name_en, gu.phone_e164
        from public.student_guardian sg join public.guardian gu on gu.id = sg.guardian_id
       where sg.student_id = e.student_id and sg.to_date is null and sg.receives_academic and gu.phone_e164 is not null
       order by sg.is_primary desc, sg.priority asc limit 1
    ) g on true
   where e.section_id = v_hw.section_id and e.status = 'active' and e.deleted_at is null and st.deleted_at is null
     and not exists (select 1 from public.homework_submission s where s.homework_id = p_homework_id and s.enrolment_id = e.id and s.status in ('submitted', 'checked'))
   order by st.name_en;
end;
$$;
revoke execute on function public.homework_non_submitters(uuid) from public, anon;
grant execute on function public.homework_non_submitters(uuid) to authenticated;

create or replace function app.fn_ensure_homework_missing_template(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t uuid;
begin
  insert into public.message_template (tenant_id, code, channel, name, audience_entity, category)
  values (p_tenant_id, 'homework_missing', 'sms', 'Homework not submitted', 'guardian', 'homework') on conflict do nothing;
  select id into v_t from public.message_template where tenant_id = p_tenant_id and code = 'homework_missing';
  if not exists (select 1 from public.message_template_version where template_id = v_t) then
    insert into public.message_template_version (template_id, version_no, message_class, body_en, body_ur, is_published, published_at)
    values (v_t, 1, 'reminder',
            'Dear {{guardian_name}}, {{student_name}} has not yet submitted "{{title}}" ({{subject}}), which was due on {{due_date}}. Please help them complete it.',
            'محترم {{guardian_name}}، {{student_name}} نے "{{title}}" ({{subject}}) جمع نہیں کرایا جس کی آخری تاریخ {{due_date}} تھی۔ براہ کرم مکمل کرنے میں مدد کریں۔', true, now());
  end if;
end;
$$;
revoke execute on function app.fn_ensure_homework_missing_template(uuid) from public, anon, authenticated;

create or replace function public.notify_non_submitters(p_homework_id uuid, p_enrolment_ids uuid[], p_include_on_leave boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hw      public.homework%rowtype;
  v_subject text;
  v_today   date := app.fn_karachi_today();
  v_cap     int;
  v_used    int;
  v_ver     uuid;
  v_row     record;
  v_body    text;
  v_msg     uuid;
  v_sched   timestamptz;
  v_now     timestamptz := now();
  v_queued  int := 0;
  v_dupes   int := 0;
  v_nophone int := 0;
  v_leave   int := 0;
begin
  select * into v_hw from public.homework where id = p_homework_id and tenant_id = app.auth_tenant_id() and status = 'published';
  if not found or not app.fn_teacher_of_homework(p_homework_id) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_hw.due_date >= v_today then
    raise exception 'NOT_YET_DUE' using errcode = '55000', detail = format('due_date=%s', v_hw.due_date);
  end if;
  if p_enrolment_ids is null or cardinality(p_enrolment_ids) = 0 or cardinality(p_enrolment_ids) > 300 then
    raise exception 'SELECTION_MUST_BE_1_TO_300' using errcode = '22023';
  end if;
  if exists (select 1 from unnest(p_enrolment_ids) x where x not in (select ns.enrolment_id from public.homework_non_submitters(p_homework_id) ns)) then
    raise exception 'NOT_A_NON_SUBMITTER' using errcode = '22023';
  end if;

  select coalesce((select daily_cap_per_campus from public.homework_notification_policy where tenant_id = v_hw.tenant_id), 100) into v_cap;
  select count(*) into v_used from public.homework_notification where tenant_id = v_hw.tenant_id and campus_id = v_hw.campus_id and sent_on = v_today and status = 'queued';
  select name_en into v_subject from public.subject where id = v_hw.subject_id;
  perform app.fn_ensure_homework_missing_template(v_hw.tenant_id);
  select v.id into v_ver from public.message_template t join public.message_template_version v on v.template_id = t.id
   where t.tenant_id = v_hw.tenant_id and t.code = 'homework_missing' and v.is_published order by v.version_no desc limit 1;
  v_sched := now() + interval '15 minutes';
  if public.is_quiet_now(v_hw.tenant_id, v_sched) then
    v_sched := public.get_next_quiet_window_end(v_hw.tenant_id, v_sched);
  end if;

  for v_row in select * from public.homework_non_submitters(p_homework_id) ns where ns.enrolment_id = any (p_enrolment_ids) order by ns.student_name loop
    if v_row.on_leave and not p_include_on_leave then
      v_leave := v_leave + 1;
      continue;
    end if;
    if v_row.notified_today then
      v_dupes := v_dupes + 1;
      continue;
    end if;
    if v_row.guardian_phone is null then
      insert into public.homework_notification (tenant_id, campus_id, homework_id, enrolment_id, status, created_by)
      values (v_hw.tenant_id, v_hw.campus_id, p_homework_id, v_row.enrolment_id, 'skipped_no_phone', (select auth.uid())) on conflict do nothing;
      v_nophone := v_nophone + 1;
      continue;
    end if;
    if v_used + v_queued >= v_cap then
      raise exception 'DAILY_CAP_REACHED' using errcode = '54000', detail = format('cap=%s used=%s', v_cap, v_used + v_queued);
    end if;
    v_body := public.render_template(v_ver, jsonb_build_object('guardian_name', v_row.guardian_name, 'student_name', v_row.student_name, 'title', v_hw.title, 'subject', v_subject, 'due_date', to_char(v_hw.due_date, 'DD-MM-YYYY')),
                                     coalesce((select g.preferred_language from public.guardian g join public.student_guardian sg on sg.guardian_id = g.id join public.enrolment e on e.student_id = sg.student_id
                                                where e.id = v_row.enrolment_id and sg.to_date is null and g.phone_e164 = v_row.guardian_phone limit 1), 'en'));
    insert into public.message (tenant_id, campus_id, recipient_type, recipient_phone, channel, body, status, scheduled_at, idempotency_key, template_version_id, message_class, metadata)
    values (v_hw.tenant_id, v_hw.campus_id, 'guardian', v_row.guardian_phone, 'sms', v_body, 'queued', v_sched,
            'hw_missing:' || p_homework_id || ':' || v_row.enrolment_id || ':' || v_today, v_ver, 'reminder', jsonb_build_object('homework_id', p_homework_id, 'priority', 'low'))
    on conflict do nothing
    returning id into v_msg;
    insert into public.homework_notification (tenant_id, campus_id, homework_id, enrolment_id, status, message_id, created_by)
    values (v_hw.tenant_id, v_hw.campus_id, p_homework_id, v_row.enrolment_id, 'queued', v_msg, (select auth.uid())) on conflict do nothing;
    v_queued := v_queued + 1;
  end loop;
  return jsonb_build_object('queued', v_queued, 'duplicates', v_dupes, 'no_phone', v_nophone, 'on_leave', v_leave);
end;
$$;
revoke execute on function public.notify_non_submitters(uuid, uuid[], boolean) from public, anon;
grant execute on function public.notify_non_submitters(uuid, uuid[], boolean) to authenticated;
