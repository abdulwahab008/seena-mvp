-- FR-G12: automated absentee SMS to parent.
--
--   * "Register was never submitted" (AC5's own trap) is defined as
--     "fewer attendance_day rows exist for section+date than the
--     section has active enrolments" (section_register_submitted()),
--     not merely "zero rows" — rpc_bulk_mark_attendance() (FR-G04)
--     always expands to a full per-student row set, but the lower-level
--     save_attendance_register() it wraps is independently granted to
--     authenticated (20260731490000/20260731510000) and accepts an
--     arbitrary partial p_marks array, so a genuinely partial
--     submission (some students marked, most not) is possible and must
--     be treated the same as "never submitted," not silently ignored.
--   * absentees_for_date() re-reads attendance_day.status live at call
--     time, not a snapshot taken earlier in the day — a student marked
--     absent at 08:30 and corrected to present by 10:00 (AC2) is simply
--     absent from the candidate set the 10:30 run sees. No special-case
--     code for this; it falls out of not caching anything.
--   * absentees_for_date() and sections_not_marked() are SECURITY
--     DEFINER (bypasses attendance_day/student/guardian RLS) and
--     granted to authenticated for the UI's own direct reads — each
--     therefore embeds its own tenant + campus-scope filter exactly
--     like this codebase's other SECURITY DEFINER finder functions
--     (fn_find_guardian_by_cnic, fn_suggest_family_group,
--     v_guardian_children), rather than relying on
--     dispatch_absentee_notifications()'s own check, which only
--     protects that one call path — a direct RPC call to either
--     function would otherwise bypass it entirely. The tenant check is
--     null-safe (app.auth_tenant_id() is null) so a service-role/cron
--     caller (no JWT) still sees every tenant, matching every other
--     System-actor function this session has built.
--   * Idempotency is the table's own UNIQUE(enrolment_id,
--     notification_date, channel), exactly FR-B05's on-conflict-do-
--     nothing dedupe pattern, not a separate dedupe_key column — the
--     natural key already is one (AC3). dispatch_absentee_notifications
--     also skips any candidate that already has a row for today before
--     touching the cost/cap accounting at all, so a re-run's own
--     already-queued candidates can never be double-counted against the
--     cap and can never prematurely trip it (see below).
--   * No language-preference column exists on guardian; language is
--     inferred the same way FR-B05 already infers admissions Urdu vs.
--     English (child_name_ur is not null) — guardian.name_ur is not
--     null here, reusing that exact established proxy. The rendered SMS
--     body itself uses the student's own name_ur when language='ur' and
--     it's set (student.name_ur), falling back to name_en — a
--     guardian's own name proxy decides the language, but the child's
--     name inside an Urdu message should itself be Urdu when available.
--   * cost_paisa is computed from a segment count (160 chars/segment
--     for 'en', 70 for 'ur' — the FR's own note on why Urdu triples
--     cost), at a flat placeholder rate per segment; no SMS provider is
--     integrated yet, so this is deliberately a stand-in for a future
--     per-provider rate table, not a real billing figure.
--   * daily_sms_cap_paisa lives on campus, not attendance_policy — it's
--     a general messaging budget, not an attendance-marking rule, and
--     future non-attendance notifications (e.g. fee reminders) would
--     share the same cap. Hitting the cap mid-run simply stops the loop
--     without writing a row for the remaining absentees — no new status
--     value is minted beyond the FR's own literal 5-value enum, and a
--     later re-run (that day or once the cap is raised) picks up
--     exactly the un-queued remainder for free. The whole read-spend /
--     check-cap / insert sequence runs under a
--     pg_advisory_xact_lock keyed on (campus_id, date) — the same
--     count-then-insert race FR-B05's fn_queue_appointment_reminders()
--     already documents and locks against — so two overlapping dispatch
--     calls for the same campus+date can never jointly exceed the cap.
--   * No pg_cron locally, same as every other System-actor function
--     this session has built: dispatch_absentee_notifications() is a
--     real, tested, service_role-grantable function a daily 10:30 PKT
--     cron would call, not actually scheduled.

alter table public.campus add column daily_sms_cap_paisa int check (daily_sms_cap_paisa is null or daily_sms_cap_paisa >= 0);

create type public.notification_channel as enum ('sms', 'whatsapp', 'push');
create type public.notification_language as enum ('en', 'ur');
create type public.notification_status as enum ('queued', 'sent', 'failed', 'skipped_no_contact', 'skipped_optout');

create table public.attendance_notification (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenant(id) on delete cascade,
  campus_id         uuid not null references public.campus(id) on delete cascade,
  enrolment_id      uuid not null references public.enrolment(id) on delete cascade,
  notification_date date not null,
  channel           public.notification_channel not null default 'sms',
  template_code     text not null,
  language          public.notification_language not null,
  recipient_msisdn  text,
  status            public.notification_status not null,
  provider_message_id text,
  cost_paisa        int not null default 0 check (cost_paisa >= 0),
  created_at        timestamptz not null default clock_timestamp(),
  constraint uq_attendance_notification unique (enrolment_id, notification_date, channel)
);

create index idx_att_notif_campus_date on public.attendance_notification (campus_id, notification_date);
create index idx_att_notif_exceptions on public.attendance_notification (campus_id, notification_date) where status = 'skipped_no_contact';

create trigger attendance_notification_audit after insert or update or delete on public.attendance_notification
  for each row execute function app.tg_audit_row();

-- A section's register counts as submitted only once it has at least
-- as many attendance_day rows for the date as it had enrolments
-- actually active ON THAT DATE (joined_on/left_on, not today's
-- status) — "some rows but not all" (a partial save_attendance_
-- register() call) is treated the same as zero rows, not as submitted.
-- A section with zero enrolments active on that date is vacuously
-- submitted (0 >= 0), so an empty section never clutters the
-- not-marked list, and a section's OTHER, unrelated dates never
-- retroactively flip between submitted/not-submitted just because a
-- new student joined later.
create or replace function public.section_register_submitted(p_section_id uuid, p_date date)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (
    select count(*) from public.attendance_day ad where ad.section_id = p_section_id and ad.attendance_date = p_date
  ) >= (
    select count(*) from public.enrolment e
      join public.student s on s.id = e.student_id
     where e.section_id = p_section_id
       and e.joined_on <= p_date and (e.left_on is null or e.left_on >= p_date)
       and s.status = 'active'
  );
$$;

revoke execute on function public.section_register_submitted(uuid, date) from public, anon;
grant execute on function public.section_register_submitted(uuid, date) to authenticated, service_role;

create or replace function public.absentees_for_date(p_campus_id uuid, p_date date)
returns table (
  enrolment_id uuid,
  student_name text,
  student_name_ur text,
  gr_number    text,
  section_id   uuid,
  section_label text,
  guardian_id  uuid,
  phone_e164   text,
  language     public.notification_language
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.id, s.name_en, s.name_ur, s.gr_number, e.section_id,
    cl.name_en || ' · ' || cs.name,
    g.id, g.phone_e164,
    case when g.name_ur is not null then 'ur' else 'en' end::public.notification_language
    from public.attendance_day ad
    join public.enrolment e on e.id = ad.enrolment_id
    join public.student s on s.id = e.student_id
    join public.class_section cs on cs.id = e.section_id
    join public.class_level cl on cl.id = cs.class_level_id
    left join public.student_guardian sg on sg.student_id = s.id and sg.is_primary and sg.to_date is null
    left join public.guardian g on g.id = sg.guardian_id
   where ad.campus_id = p_campus_id
     and ad.attendance_date = p_date
     and ad.status = 'absent'
     and (app.auth_tenant_id() is null or ad.tenant_id = app.auth_tenant_id())
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or ad.campus_id = any(app.auth_campus_ids()))
     and public.section_register_submitted(e.section_id, p_date);
$$;

revoke execute on function public.absentees_for_date(uuid, date) from public, anon;
grant execute on function public.absentees_for_date(uuid, date) to authenticated, service_role;

create or replace function public.sections_not_marked(p_campus_id uuid, p_date date)
returns table (section_id uuid, section_label text)
language sql
stable
security definer
set search_path = ''
as $$
  select cs.id, cl.name_en || ' · ' || cs.name
    from public.class_section cs
    join public.class_level cl on cl.id = cs.class_level_id
   where cs.campus_id = p_campus_id
     and cs.is_active
     and (app.auth_tenant_id() is null or cs.tenant_id = app.auth_tenant_id())
     and (app.auth_tenant_id() is null or app.auth_role() in ('super_admin', 'owner') or cs.campus_id = any(app.auth_campus_ids()))
     and not public.section_register_submitted(cs.id, p_date);
$$;

revoke execute on function public.sections_not_marked(uuid, date) from public, anon;
grant execute on function public.sections_not_marked(uuid, date) to authenticated, service_role;

create or replace function public.dispatch_absentee_notifications(p_campus_id uuid, p_date date default current_date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row          record;
  v_queued       int := 0;
  v_skipped      int := 0;
  v_body_len     int;
  v_segment_len  int;
  v_cost         int;
  v_spent_today  int;
  v_cap          int;
  v_name         text;
  c_paisa_per_segment constant int := 100;
begin
  if app.auth_tenant_id() is not null and app.auth_role() not in ('super_admin', 'owner', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if app.auth_tenant_id() is not null and not exists (select 1 from public.campus where id = p_campus_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- Serializes the whole read-spend/check-cap/insert sequence per
  -- campus+date, the same class of race FR-B05's fn_queue_appointment_
  -- reminders() already locks against.
  perform pg_advisory_xact_lock(hashtextextended('absentee-sms-cap:' || p_campus_id::text || ':' || p_date::text, 0));

  select daily_sms_cap_paisa into v_cap from public.campus where id = p_campus_id;
  select coalesce(sum(cost_paisa), 0) into v_spent_today
    from public.attendance_notification
   where campus_id = p_campus_id and notification_date = p_date;

  for v_row in select * from public.absentees_for_date(p_campus_id, p_date) loop
    -- Already handled by an earlier run today — skip before touching
    -- cost/cap accounting at all, so a re-run's own already-queued
    -- candidates can never inflate v_spent_today or trip the cap early.
    if exists (
      select 1 from public.attendance_notification
       where enrolment_id = v_row.enrolment_id and notification_date = p_date and channel = 'sms'
    ) then
      continue;
    end if;

    if v_row.guardian_id is null or v_row.phone_e164 is null then
      insert into public.attendance_notification (
        tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
      )
      select tenant_id, p_campus_id, v_row.enrolment_id, p_date, 'sms', 'absentee_daily_' || v_row.language::text, v_row.language, null, 'skipped_no_contact', 0
        from public.enrolment where id = v_row.enrolment_id
      on conflict (enrolment_id, notification_date, channel) do nothing;
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_name := case when v_row.language = 'ur' then coalesce(v_row.student_name_ur, v_row.student_name) else v_row.student_name end;
    v_body_len := length(
      case v_row.language
        when 'ur' then v_name || ' (GR ' || v_row.gr_number || ') ' || v_row.section_label || ' ' || p_date::text || ' غیر حاضر'
        else v_name || ' (GR ' || v_row.gr_number || ') was absent from ' || v_row.section_label || ' on ' || p_date::text || '.'
      end
    );
    v_segment_len := case v_row.language when 'ur' then 70 else 160 end;
    v_cost := ceil(v_body_len::numeric / v_segment_len) * c_paisa_per_segment;

    if v_cap is not null and v_spent_today + v_cost > v_cap then
      exit; -- daily budget reached; the rest are picked up by a later re-run
    end if;

    insert into public.attendance_notification (
      tenant_id, campus_id, enrolment_id, notification_date, channel, template_code, language, recipient_msisdn, status, cost_paisa
    )
    select tenant_id, p_campus_id, v_row.enrolment_id, p_date, 'sms', 'absentee_daily_' || v_row.language::text, v_row.language, v_row.phone_e164, 'queued', v_cost
      from public.enrolment where id = v_row.enrolment_id
    on conflict (enrolment_id, notification_date, channel) do nothing;
    v_queued := v_queued + 1;
    v_spent_today := v_spent_today + v_cost;
  end loop;

  return jsonb_build_object(
    'queued', v_queued,
    'skipped_no_contact', v_skipped,
    'sections_not_marked', (select count(*) from public.sections_not_marked(p_campus_id, p_date))
  );
end;
$$;

revoke execute on function public.dispatch_absentee_notifications(uuid, date) from public, anon;
grant execute on function public.dispatch_absentee_notifications(uuid, date) to authenticated, service_role;

alter table public.attendance_notification enable row level security;

create policy notif_campus_read on public.attendance_notification
  for select to authenticated
  using (
    tenant_id = app.auth_tenant_id()
    and (app.auth_role() in ('super_admin', 'owner') or campus_id = any(app.auth_campus_ids()))
  );
