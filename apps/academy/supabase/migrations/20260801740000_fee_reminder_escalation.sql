-- FR-K26: automated fee reminder escalation.
--
-- A ladder of rungs (day 1 SMS, day 7 WhatsApp, day 15 phone-call task, ...)
-- driven by fee_reminder_rule. Consolidated PER GUARDIAN: a parent with three
-- children each holding an overdue challan gets one message listing all
-- three, not three before breakfast. Each (challan, rung) fires at most once;
-- a challan paid mid-ladder halts it (logged, nothing sent); messages created
-- during quiet hours are scheduled for the end of the quiet window. Wording
-- lives in message_template versions (Urdu included), never concatenated here.

create table public.fee_reminder_rule (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  campus_id     uuid references public.campus(id) on delete cascade,
  rung_code     text not null check (rung_code ~ '^[a-z][a-z0-9_]{1,40}$'),
  offset_days   int not null check (offset_days between 1 and 365),
  channel       text not null check (channel in ('sms', 'whatsapp', 'task', 'notification')),
  template_code text,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint fee_reminder_rule_template check (channel in ('task') or template_code is not null)
);
create unique index uq_fee_reminder_rule on public.fee_reminder_rule (tenant_id, coalesce(campus_id, '00000000-0000-0000-0000-000000000000'::uuid), rung_code);
create index idx_fee_reminder_rule_tenant on public.fee_reminder_rule (tenant_id, is_active);

create table public.fee_reminder_log (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  challan_id  uuid not null references public.fee_challan(id) on delete cascade,
  rung_code   text not null,
  guardian_id uuid references public.guardian(id) on delete set null,
  channel     text not null,
  message_id  uuid references public.message(id) on delete set null,
  status      text not null check (status in ('queued', 'task', 'notified', 'halted', 'skipped_no_guardian_phone', 'skipped_no_account')),
  created_at  timestamptz not null default now(),
  constraint fee_reminder_rung_uq unique (challan_id, rung_code)
);
create index idx_fee_reminder_log_scope on public.fee_reminder_log (tenant_id, campus_id, created_at desc);

create table public.fee_follow_up_task (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenant(id) on delete cascade,
  campus_id   uuid not null references public.campus(id) on delete cascade,
  guardian_id uuid not null references public.guardian(id) on delete cascade,
  rung_code   text not null,
  summary     text not null,
  total_due_paisa bigint not null,
  status      text not null default 'open' check (status in ('open', 'done')),
  created_at  timestamptz not null default now(),
  completed_at timestamptz
);
create index idx_fee_follow_up_open on public.fee_follow_up_task (tenant_id, campus_id, status);

alter table public.fee_reminder_rule enable row level security;
alter table public.fee_reminder_log enable row level security;
alter table public.fee_follow_up_task enable row level security;

create policy fee_reminder_rule_read on public.fee_reminder_rule for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal'));
create policy fee_reminder_log_campus_read on public.fee_reminder_log for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));
create policy fee_follow_up_task_campus_read on public.fee_follow_up_task for select to authenticated
  using (tenant_id = app.auth_tenant_id() and app.auth_role() in ('owner', 'super_admin', 'accountant', 'principal')
         and (app.auth_role() in ('owner', 'super_admin') or campus_id = any(app.auth_campus_ids())));

-- Default ladder + the templates it points at (English and Urdu, as templates).
create or replace function public.seed_default_fee_reminder_rules(p_campus_id uuid default null)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_t      uuid;
  v_n      int := 0;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  insert into public.message_template (tenant_id, code, channel, name, audience_entity, category)
  values (v_tenant, 'fee_reminder_sms', 'sms', 'Fee reminder (SMS)', 'guardian', 'fees') on conflict do nothing;
  insert into public.message_template (tenant_id, code, channel, name, audience_entity, category)
  values (v_tenant, 'fee_reminder_wa', 'whatsapp', 'Fee reminder (WhatsApp)', 'guardian', 'fees') on conflict do nothing;

  for v_t in select id from public.message_template where tenant_id = v_tenant and code in ('fee_reminder_sms', 'fee_reminder_wa') loop
    if not exists (select 1 from public.message_template_version where template_id = v_t) then
      insert into public.message_template_version (template_id, version_no, message_class, body_en, body_ur, is_published, published_at)
      values (v_t, 1, 'reminder',
              'Dear {{guardian_name}}, fee for {{children}} is overdue. Total due: PKR {{total_due}}. Please pay at the earliest.',
              'محترم {{guardian_name}}، {{children}} کی فیس واجب الادا ہے۔ کل رقم: PKR {{total_due}}۔ براہ کرم جلد ادا کریں۔', true, now());
    end if;
  end loop;

  insert into public.fee_reminder_rule (tenant_id, campus_id, rung_code, offset_days, channel, template_code) values
    (v_tenant, p_campus_id, 'sms_d1', 1, 'sms', 'fee_reminder_sms'),
    (v_tenant, p_campus_id, 'wa_d7', 7, 'whatsapp', 'fee_reminder_wa'),
    (v_tenant, p_campus_id, 'task_d15', 15, 'task', null)
  on conflict do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.seed_default_fee_reminder_rules(uuid) from public, anon;
grant execute on function public.seed_default_fee_reminder_rules(uuid) to authenticated;

create or replace function public.set_fee_reminder_rule_active(p_rule_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  update public.fee_reminder_rule set is_active = p_active where id = p_rule_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'RULE_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;
revoke execute on function public.set_fee_reminder_rule_active(uuid, boolean) from public, anon;
grant execute on function public.set_fee_reminder_rule_active(uuid, boolean) to authenticated;

-- The daily job (09:00 PKT). p_now exists so quiet hours are testable.
create or replace function public.fees_reminder_escalation(p_run_date date default null, p_tenant_id uuid default null, p_now timestamptz default clock_timestamp())
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_run     date := coalesce(p_run_date, app.fn_karachi_today());
  v_rule    record;
  v_group   record;
  v_ver     uuid;
  v_lang    text;
  v_body    text;
  v_msg     uuid;
  v_sched   timestamptz;
  v_queued  int := 0;
  v_tasks   int := 0;
  v_halted  int := 0;
  v_skipped int := 0;
begin
  for v_rule in
    select * from public.fee_reminder_rule where is_active and (p_tenant_id is null or tenant_id = p_tenant_id) order by tenant_id, offset_days
  loop
    -- ladder halted: the challan was paid (or cancelled) after earlier rungs went out
    insert into public.fee_reminder_log (tenant_id, campus_id, challan_id, rung_code, channel, status)
    select c.tenant_id, c.campus_id, c.id, v_rule.rung_code, v_rule.channel, 'halted'
      from public.fee_challan c
     where c.tenant_id = v_rule.tenant_id and (v_rule.campus_id is null or c.campus_id = v_rule.campus_id)
       and c.due_date = v_run - v_rule.offset_days and c.status in ('paid', 'cancelled')
       and exists (select 1 from public.fee_reminder_log l where l.challan_id = c.id)
    on conflict (challan_id, rung_code) do nothing;
    get diagnostics v_skipped = row_count;
    v_halted := v_halted + v_skipped;

    -- one group per guardian: every overdue challan of every child on this rung
    for v_group in
      with due as (
        select c.id as challan_id, c.tenant_id, c.campus_id, c.challan_no, st.name_en as student_name,
               c.net_paisa - coalesce((select sum(a.amount_paisa) from public.fee_payment_allocation a where a.challan_id = c.id), 0) as bal,
               (select sg.guardian_id from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
                 where sg.student_id = e.student_id and sg.to_date is null and sg.receives_billing
                 order by sg.is_primary desc, sg.priority asc limit 1) as guardian_id
          from public.fee_challan c
          join public.enrolment e on e.id = c.enrolment_id
          join public.student st on st.id = e.student_id
         where c.tenant_id = v_rule.tenant_id and (v_rule.campus_id is null or c.campus_id = v_rule.campus_id)
           and c.due_date = v_run - v_rule.offset_days and c.status in ('unpaid', 'part_paid') and c.deleted_at is null
           and not exists (select 1 from public.fee_reminder_log l where l.challan_id = c.id and l.rung_code = v_rule.rung_code)
      )
      select d.guardian_id, d.tenant_id, min(d.campus_id::text)::uuid as campus_id,
             array_agg(d.challan_id order by d.challan_no) as challan_ids,
             string_agg(d.student_name || ' (challan ' || d.challan_no || ')', '; ' order by d.challan_no) as children,
             sum(d.bal)::bigint as total_due,
             g.name_en as guardian_name, g.phone_e164, g.preferred_language, g.auth_user_id
        from due d left join public.guardian g on g.id = d.guardian_id
       where d.bal > 0
       group by d.guardian_id, d.tenant_id, g.name_en, g.phone_e164, g.preferred_language, g.auth_user_id
    loop
      v_msg := null;

      if v_group.guardian_id is null or (v_rule.channel in ('sms', 'whatsapp') and v_group.phone_e164 is null) then
        insert into public.fee_reminder_log (tenant_id, campus_id, challan_id, rung_code, guardian_id, channel, status)
        select v_group.tenant_id, v_group.campus_id, cid, v_rule.rung_code, v_group.guardian_id, v_rule.channel, 'skipped_no_guardian_phone'
          from unnest(v_group.challan_ids) cid on conflict (challan_id, rung_code) do nothing;
        v_skipped := v_skipped + 1;
        continue;
      end if;

      if v_rule.channel in ('sms', 'whatsapp') then
        select v.id into v_ver from public.message_template t join public.message_template_version v on v.template_id = t.id
         where t.tenant_id = v_rule.tenant_id and t.code = v_rule.template_code and v.is_published order by v.version_no desc limit 1;
        if v_ver is null then
          continue;
        end if;
        v_lang := coalesce(v_group.preferred_language, 'en');
        v_body := public.render_template(v_ver, jsonb_build_object('guardian_name', v_group.guardian_name, 'children', v_group.children, 'total_due', to_char(v_group.total_due / 100.0, 'FM999,999,990')), v_lang);
        v_sched := case when public.is_quiet_now(v_rule.tenant_id, p_now) then public.get_next_quiet_window_end(v_rule.tenant_id, p_now) else p_now end;

        insert into public.message (tenant_id, campus_id, recipient_type, recipient_id, recipient_phone, channel, body, status, scheduled_at, idempotency_key, template_version_id, message_class, metadata)
        values (v_rule.tenant_id, v_group.campus_id, 'guardian', v_group.guardian_id, v_group.phone_e164, v_rule.channel::public.comm_channel, v_body, 'queued', v_sched,
                'fee_reminder:' || v_group.guardian_id || ':' || v_rule.rung_code || ':' || v_run, v_ver, 'reminder',
                jsonb_build_object('rung', v_rule.rung_code, 'challan_ids', v_group.challan_ids))
        on conflict do nothing
        returning id into v_msg;
        v_queued := v_queued + 1;
      elsif v_rule.channel = 'task' then
        insert into public.fee_follow_up_task (tenant_id, campus_id, guardian_id, rung_code, summary, total_due_paisa)
        values (v_group.tenant_id, v_group.campus_id, v_group.guardian_id, v_rule.rung_code, v_group.children, v_group.total_due);
        v_tasks := v_tasks + 1;
      elsif v_rule.channel = 'notification' then
        if v_group.auth_user_id is null then
          insert into public.fee_reminder_log (tenant_id, campus_id, challan_id, rung_code, guardian_id, channel, status)
          select v_group.tenant_id, v_group.campus_id, cid, v_rule.rung_code, v_group.guardian_id, 'notification', 'skipped_no_account' from unnest(v_group.challan_ids) cid on conflict (challan_id, rung_code) do nothing;
          continue;
        end if;
        insert into public.user_notification (tenant_id, user_id, kind, title, body, link)
        values (v_group.tenant_id, v_group.auth_user_id, 'fee_reminder', 'Fee reminder', v_group.children || ' — total due PKR ' || to_char(v_group.total_due / 100.0, 'FM999,999,990'), '/portal/fees');
      end if;

      insert into public.fee_reminder_log (tenant_id, campus_id, challan_id, rung_code, guardian_id, channel, message_id, status)
      select v_group.tenant_id, v_group.campus_id, cid, v_rule.rung_code, v_group.guardian_id, v_rule.channel, v_msg,
             case v_rule.channel when 'task' then 'task' when 'notification' then 'notified' else 'queued' end
        from unnest(v_group.challan_ids) cid on conflict (challan_id, rung_code) do nothing;
    end loop;
  end loop;

  return jsonb_build_object('run_date', v_run, 'queued', v_queued, 'tasks', v_tasks, 'halted', v_halted, 'skipped', v_skipped);
end;
$$;
revoke execute on function public.fees_reminder_escalation(date, uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.fees_reminder_escalation(date, uuid, timestamptz) to service_role;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('fees_reminder_escalation', '0 4 * * *', 'select public.fees_reminder_escalation();');
  end if;
exception
  when others then null;
end;
$$;
