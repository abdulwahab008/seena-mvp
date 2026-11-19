-- Admissions reminders and absentee alerts were queued into tables the message worker never reads
-- (outbound_message, attendance_notification); it only sends public.message. So no follow-up
-- reminder, interview/test reminder or absentee SMS ever reached anyone.
--
-- 1. The three reminder queue functions accept a service_role caller, so a daily timer can run them
--    for every tenant (their comments already planned for "a real future cron"), and follow-up
--    reminders skip enquiries that have already become applications.
-- 2. Each newly queued row in either table is copied into public.message as an SMS with plain
--    English or Urdu wording, keyed on the source row so it is sent once. SMS because the worker
--    has no WhatsApp transport; WhatsApp-opted-in parents still get the SMS.

create or replace function public.fn_queue_followup_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row     record;
  v_phone   text;
  v_tmpl    text;
  v_count   int := 0;
begin
  -- The daily timer calls as service_role, which carries no app_role and sweeps every tenant.
  if coalesce(auth.role(), '') <> 'service_role' and app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC/defense-in-depth: an authenticated officer's manual "check now"
  -- only ever sweeps their own tenant (app.auth_tenant_id() is never
  -- null for them) — only a service_role caller (a real future cron,
  -- which has no tenant of its own) sweeps every tenant in one pass.
  for v_row in
    select f.id, f.tenant_id, f.campus_id, f.enquiry_id, f.assigned_to
      from public.admission_followup f
     where f.completed_at is null
       -- Nothing left to chase once the enquiry has become an application.
       and exists (select 1 from public.admission_enquiry e where e.id = f.enquiry_id and e.status = 'open')
       and f.due_at <= clock_timestamp() + interval '30 minutes'
       and (app.auth_tenant_id() is null or f.tenant_id = app.auth_tenant_id())
  loop
    if v_row.assigned_to is null then
      continue;
    end if;
    select phone_e164 into v_phone from public.app_user where user_id = v_row.assigned_to;
    if v_phone is null then
      continue;
    end if;

    select template_id into v_tmpl from public.message_template
     where tenant_id = v_row.tenant_id and code = 'followup_reminder' and channel = 'whatsapp' and locale = 'en';

    insert into public.outbound_message (
      tenant_id, campus_id, enquiry_id, reminder_kind, followup_id, channel, template_id, locale, to_phone, payload, dedupe_key
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.enquiry_id, 'followup_officer', v_row.id, 'whatsapp', v_tmpl, 'en', v_phone,
      jsonb_build_object('followup_id', v_row.id), v_row.id::text || ':followup_officer:whatsapp'
    )
    on conflict (dedupe_key) do nothing;
    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

create or replace function public.fn_queue_appointment_reminders()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row      record;
  v_locale   text;
  v_channel  public.followup_channel;
  v_tmpl     text;
  v_recent   int;
  v_status   public.outbound_status;
  v_count    int := 0;
begin
  -- The daily timer calls as service_role, which carries no app_role and sweeps every tenant.
  if coalesce(auth.role(), '') <> 'service_role' and app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC/defense-in-depth: same tenant-scoping rule as
  -- fn_queue_followup_reminders() — an authenticated officer only
  -- sweeps their own tenant; only service_role sweeps every tenant.
  for v_row in
    select
      aa.tenant_id, aa.campus_id, aa.enquiry_id,
      ae.phone_e164, ae.whatsapp_opt_in, ae.child_name_ur,
      ats.id as test_sitting_id, null::uuid as interview_id, 'test_reminder' as code, ats.starts_at
    from public.admission_test_sitting ats
    join public.admission_test_candidate atc on atc.sitting_id = ats.id and atc.cancelled_at is null
    join public.admission_application aa on aa.id = atc.application_id
    join public.admission_enquiry ae on ae.id = aa.enquiry_id
   where ats.starts_at <= clock_timestamp() + interval '24 hours' and ats.starts_at > clock_timestamp()
     and (app.auth_tenant_id() is null or aa.tenant_id = app.auth_tenant_id())
    union all
    select
      aa.tenant_id, aa.campus_id, aa.enquiry_id,
      ae.phone_e164, ae.whatsapp_opt_in, ae.child_name_ur,
      null::uuid as test_sitting_id, ai.id as interview_id, 'interview_reminder' as code, ai.starts_at
    from public.admission_interview ai
    join public.admission_application aa on aa.id = ai.application_id
    join public.admission_enquiry ae on ae.id = aa.enquiry_id
   where ai.status = 'scheduled' and ai.starts_at <= clock_timestamp() + interval '24 hours' and ai.starts_at > clock_timestamp()
     and (app.auth_tenant_id() is null or aa.tenant_id = app.auth_tenant_id())
  loop
    v_locale := case when v_row.child_name_ur is not null then 'ur' else 'en' end;
    v_channel := case when v_row.whatsapp_opt_in then 'whatsapp' else 'sms' end;

    -- AC/defense-in-depth: an advisory lock keyed on the enquiry
    -- serializes the count-then-insert rate-cap check — without it, two
    -- concurrent appointments due for the same enquiry could each read
    -- the same "2 already sent" count and both slip in as 'queued'
    -- instead of one correctly landing as 'rate_capped'. The same
    -- untestable-in-single-connection-pgTAP caveat already documented
    -- elsewhere in this codebase (FR-K10, FR-K16, FR-B07, FR-B11).
    perform pg_advisory_xact_lock(hashtextextended('appointment-reminder-rate-cap:' || v_row.enquiry_id::text, 0));

    select count(*) into v_recent from public.outbound_message
     where enquiry_id = v_row.enquiry_id and reminder_kind = 'appointment_parent'
       and created_at > clock_timestamp() - interval '24 hours';
    v_status := case when v_recent >= 2 then 'rate_capped' else 'queued' end;

    select template_id into v_tmpl from public.message_template
     where tenant_id = v_row.tenant_id and code = v_row.code and channel = v_channel and locale = v_locale;

    insert into public.outbound_message (
      tenant_id, campus_id, enquiry_id, reminder_kind, test_sitting_id, interview_id, channel, template_id, locale, to_phone,
      payload, status, dedupe_key
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.enquiry_id, 'appointment_parent', v_row.test_sitting_id, v_row.interview_id,
      v_channel, v_tmpl, v_locale, v_row.phone_e164,
      jsonb_build_object('starts_at', v_row.starts_at), v_status,
      coalesce(v_row.test_sitting_id, v_row.interview_id)::text || ':appointment_parent:' || v_channel
    )
    on conflict (dedupe_key) do nothing;
    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

create or replace function public.fn_process_sms_fallbacks()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row   record;
  v_tmpl  text;
  v_count int := 0;
begin
  -- The daily timer calls as service_role, which carries no app_role and sweeps every tenant.
  if coalesce(auth.role(), '') <> 'service_role' and app.auth_role() not in ('super_admin', 'owner', 'principal', 'admissions_officer') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- AC/defense-in-depth: same tenant-scoping rule as the two queue
  -- functions above.
  for v_row in
    select * from public.outbound_message
     where channel = 'whatsapp' and status = 'failed' and created_at <= clock_timestamp() - interval '5 minutes'
       and (app.auth_tenant_id() is null or tenant_id = app.auth_tenant_id())
  loop
    select template_id into v_tmpl from public.message_template
     where tenant_id = v_row.tenant_id and locale = v_row.locale and channel = 'sms'
       and code = case when v_row.reminder_kind = 'followup_officer' then 'followup_reminder'
                        when v_row.test_sitting_id is not null then 'test_reminder'
                        else 'interview_reminder' end;

    insert into public.outbound_message (
      tenant_id, campus_id, enquiry_id, reminder_kind, followup_id, test_sitting_id, interview_id, channel, template_id,
      locale, to_phone, payload, dedupe_key
    ) values (
      v_row.tenant_id, v_row.campus_id, v_row.enquiry_id, v_row.reminder_kind, v_row.followup_id, v_row.test_sitting_id,
      v_row.interview_id, 'sms', v_tmpl, v_row.locale, v_row.to_phone, v_row.payload,
      regexp_replace(v_row.dedupe_key, ':whatsapp$', ':sms')
    )
    on conflict (dedupe_key) do nothing;
    if found then
      v_count := v_count + 1;
    end if;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.fn_queue_followup_reminders() from public, anon;
grant execute on function public.fn_queue_followup_reminders() to authenticated, service_role;
revoke execute on function public.fn_queue_appointment_reminders() from public, anon;
grant execute on function public.fn_queue_appointment_reminders() to authenticated, service_role;
revoke execute on function public.fn_process_sms_fallbacks() from public, anon;
grant execute on function public.fn_process_sms_fallbacks() to authenticated, service_role;

-- ── Admissions reminders -> public.message ───────────────────────────────
create or replace function app.tg_outbound_message_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_body    text;
  v_school  text;
  v_when    timestamptz;
  v_venue   text;
  v_child   text;
  v_parent  text;
  v_no      text;
  v_phone   text;
  v_what_en text;
  v_what_ur text;
begin
  if new.status <> 'queued' or new.to_phone is null then
    return new;
  end if;
  select name into v_school from public.campus where id = new.campus_id;
  select child_name, parent_name, enquiry_no, phone_e164 into v_child, v_parent, v_no, v_phone
    from public.admission_enquiry where id = new.enquiry_id;

  if new.reminder_kind = 'followup_officer' then
    select due_at into v_when from public.admission_followup where id = new.followup_id;
    v_body := format('Follow-up due %s: contact %s about %s (%s), %s.',
      to_char(v_when at time zone 'Asia/Karachi', 'DD Mon HH24:MI'), coalesce(v_parent, 'the parent'), v_child, v_no, v_phone);
  else
    if new.interview_id is not null then
      select starts_at, venue into v_when, v_venue from public.admission_interview where id = new.interview_id;
      v_what_en := 'admission interview'; v_what_ur := 'داخلہ انٹرویو';
    else
      select starts_at, venue into v_when, v_venue from public.admission_test_sitting where id = new.test_sitting_id;
      v_what_en := 'admission test'; v_what_ur := 'داخلہ ٹیسٹ';
    end if;
    if new.locale = 'ur' then
      v_body := format('یاد دہانی: %s کا %s %s کو ہے%s۔ %s',
        v_child, v_what_ur, to_char(v_when at time zone 'Asia/Karachi', 'DD-MM-YYYY HH24:MI'),
        coalesce('، ' || v_venue, ''), v_school);
    else
      v_body := format('Reminder: %s''s %s is on %s%s. %s',
        v_child, v_what_en, to_char(v_when at time zone 'Asia/Karachi', 'DD Mon YYYY, HH24:MI'),
        coalesce(' at ' || v_venue, ''), v_school);
    end if;
  end if;

  insert into public.message (tenant_id, campus_id, recipient_type, recipient_phone, channel, body, status, idempotency_key, message_class, metadata)
  values (new.tenant_id, new.campus_id, case when new.reminder_kind = 'followup_officer' then 'staff' else 'parent' end::public.comm_recipient_type,
          new.to_phone, 'sms', v_body, 'queued', 'outbound_message:' || new.id, 'reminder',
          jsonb_build_object('source', 'outbound_message', 'source_id', new.id, 'reminder_kind', new.reminder_kind))
  on conflict do nothing;
  return new;
end;
$$;

create trigger outbound_message_to_outbox
  after insert on public.outbound_message
  for each row execute function app.tg_outbound_message_to_outbox();

-- ── Absentee alerts -> public.message ────────────────────────────────────
create or replace function app.tg_attendance_notification_to_outbox()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_student text;
  v_school  text;
  v_body    text;
begin
  if new.status <> 'queued' or new.recipient_msisdn is null or new.channel = 'push' then
    return new;
  end if;
  select s.name_en into v_student from public.enrolment e join public.student s on s.id = e.student_id where e.id = new.enrolment_id;
  select name into v_school from public.campus where id = new.campus_id;
  if new.language = 'ur' then
    v_body := format('محترم والدین، %s آج %s کو اسکول سے غیر حاضر رہے۔ %s', v_student, to_char(new.notification_date, 'DD-MM-YYYY'), v_school);
  else
    v_body := format('Dear parent, %s was absent from school on %s. %s', v_student, to_char(new.notification_date, 'DD Mon YYYY'), v_school);
  end if;

  insert into public.message (tenant_id, campus_id, recipient_type, recipient_phone, channel, body, status, idempotency_key, message_class, metadata)
  values (new.tenant_id, new.campus_id, 'guardian', new.recipient_msisdn, 'sms', v_body, 'queued',
          'attendance_notification:' || new.id, 'transactional',
          jsonb_build_object('source', 'attendance_notification', 'source_id', new.id, 'enrolment_id', new.enrolment_id))
  on conflict do nothing;
  return new;
end;
$$;

create trigger attendance_notification_to_outbox
  after insert on public.attendance_notification
  for each row execute function app.tg_attendance_notification_to_outbox();
