-- Quick SMS from the front desk: one message to a section's parents, to all
-- staff of the campus, or to numbers typed in. Queued into the existing
-- outbox as one batch; the outbox dispatcher sends it.

create or replace function public.queue_quick_sms(
  p_campus_id  uuid,
  p_audience   text,
  p_section_id uuid,
  p_numbers    text[],
  p_body       text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_body      text := btrim(coalesce(p_body, ''));
  v_batch     uuid;
  v_queued    int := 0;
  v_skipped   int := 0;
  r record;
begin
  if v_tenant_id is null or not app.fn_front_desk_staff() then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.campus where id = p_campus_id and tenant_id = v_tenant_id and deleted_at is null) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if app.auth_role() not in ('super_admin', 'owner') and not (p_campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501', detail = 'campus outside your scope';
  end if;
  if v_body = '' or length(v_body) > 640 then
    raise exception 'BODY_INVALID' using errcode = '22023';
  end if;
  if p_audience not in ('section', 'staff', 'numbers') then
    raise exception 'AUDIENCE_INVALID' using errcode = '22023';
  end if;
  if p_audience = 'section' and not exists (select 1 from public.class_section where id = p_section_id and campus_id = p_campus_id and tenant_id = v_tenant_id) then
    raise exception 'SECTION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_audience = 'numbers' and coalesce(array_length(p_numbers, 1), 0) not between 1 and 100 then
    raise exception 'NUMBERS_INVALID' using errcode = '22023';
  end if;

  insert into public.message_batch (tenant_id, campus_id, title, channel, created_by, metadata)
  values (v_tenant_id, p_campus_id, 'Quick SMS', 'sms', auth.uid(), jsonb_build_object('template', 'quick_sms', 'audience', p_audience))
  returning id into v_batch;

  for r in
    with candidates as (
      select 'guardian'::public.comm_recipient_type as kind, e.student_id as rid,
             (select public.normalize_pk_phone(g.phone_e164) from public.student_guardian sg join public.guardian g on g.id = sg.guardian_id
               where sg.student_id = e.student_id and (sg.to_date is null or sg.to_date >= current_date) and g.phone_e164 is not null
               order by sg.is_primary desc, sg.priority limit 1) as phone
        from public.enrolment e
       where p_audience = 'section' and e.section_id = p_section_id and e.tenant_id = v_tenant_id
         and e.status = 'active' and e.deleted_at is null
      union all
      select 'staff', s.id, public.normalize_pk_phone(c.mobile)
        from public.staff s
        left join public.staff_private_contact c on c.staff_id = s.id
       where p_audience = 'staff' and s.tenant_id = v_tenant_id and s.employment_status = 'active'
         and (s.campus_id = p_campus_id or exists (select 1 from public.staff_campus sc where sc.staff_id = s.id and sc.campus_id = p_campus_id))
      union all
      select 'custom', null, public.normalize_pk_phone(n)
        from unnest(p_numbers) n
       where p_audience = 'numbers'
    )
    select distinct on (coalesce(phone, gen_random_uuid()::text)) kind, rid, phone from candidates
  loop
    if r.phone is null then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    insert into public.message (tenant_id, campus_id, batch_id, recipient_type, recipient_id, recipient_phone, channel, body, status, idempotency_key, metadata)
    values (v_tenant_id, p_campus_id, v_batch, r.kind, r.rid, r.phone, 'sms', v_body, 'queued',
            'quick-sms:' || v_batch || ':' || r.phone, jsonb_build_object('template', 'quick_sms'));
    v_queued := v_queued + 1;
  end loop;

  update public.message_batch set total_count = v_queued, queued_count = v_queued where id = v_batch;
  return jsonb_build_object('queued', v_queued, 'skipped', v_skipped, 'batch_id', v_batch);
end;
$$;
revoke execute on function public.queue_quick_sms(uuid, text, uuid, text[], text) from public, anon;
grant execute on function public.queue_quick_sms(uuid, text, uuid, text[], text) to authenticated;
