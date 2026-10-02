-- Enrolment must never be blocked by billing, including when the row is
-- written outside a signed-in user's request (a service-role data migration,
-- a back-filled history, an ops script).
--
-- enrolment_ai_build_fee_plan used to call public.build_fee_plan(new.id), which
-- looks the enrolment up with `tenant_id = app.auth_tenant_id()`. That is the
-- caller's JWT tenant, which is null for service_role and for any session that
-- carries no claims, so inserting an enrolment from such a context raised
-- ENROLMENT_NOT_FOUND from inside the trigger and rolled the enrolment back,
-- the opposite of what build_fee_plan's own comment promises ("Enrolment itself
-- must never be blocked by billing").
--
-- The plan-building body moves into app.build_fee_plan_for(enrolment, tenant),
-- which takes the tenant explicitly. The trigger passes new.tenant_id (the row
-- being written, which is the only tenant it can mean); the public RPC keeps
-- its signature and its caller-scoped behaviour by passing app.auth_tenant_id(),
-- so an authenticated user still cannot build a plan for another tenant's
-- enrolment and still gets ENROLMENT_NOT_FOUND for one that is not theirs.

create or replace function app.build_fee_plan_for(p_enrolment_id uuid, p_tenant_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_enrolment    public.enrolment%rowtype;
  v_structure_id uuid;
  v_plan_id      uuid;
  v_has_route    boolean;
begin
  select * into v_enrolment from public.enrolment where id = p_enrolment_id and tenant_id = p_tenant_id;
  if not found then
    raise exception 'ENROLMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  select id into v_structure_id from public.fee_structure
   where campus_id = v_enrolment.campus_id and session_id = v_enrolment.session_id and status = 'published'
   limit 1;
  if v_structure_id is null then
    -- No published structure yet for this campus/session — nothing to
    -- snapshot. Enrolment itself must never be blocked by billing not
    -- being configured yet; this is a deliberate silent no-op, not an error.
    return null;
  end if;

  select exists(
    select 1 from public.student_transport
     where student_id = v_enrolment.student_id and session_id = v_enrolment.session_id
       and opt_in and route_id is not null and to_date is null
  ) into v_has_route;

  insert into public.fee_plan (tenant_id, campus_id, enrolment_id, session_id, structure_id)
  values (v_enrolment.tenant_id, v_enrolment.campus_id, p_enrolment_id, v_enrolment.session_id, v_structure_id)
  on conflict (enrolment_id) do nothing
  returning id into v_plan_id;

  if v_plan_id is null then
    select id into v_plan_id from public.fee_plan where enrolment_id = p_enrolment_id;
    return v_plan_id;
  end if;

  insert into public.fee_plan_line (plan_id, fee_head_id, amount_paisa, frequency, billing_month_mask, source_structure_line_id)
  select v_plan_id, l.fee_head_id, l.amount_paisa, l.frequency, l.billing_month_mask, l.id
    from public.fee_structure_line l
    join public.fee_head fh on fh.id = l.fee_head_id
   where l.structure_id = v_structure_id and l.class_id = v_enrolment.class_level_id and l.group_code is null
     and (fh.code <> 'TRANSPORT' or v_has_route);

  return v_plan_id;
end;
$$;

-- Internal only: reachable through public.build_fee_plan (caller's tenant) and
-- the enrolment trigger (the row's own tenant), never directly by an API role.
revoke execute on function app.build_fee_plan_for(uuid, uuid) from public, anon, authenticated;

create or replace function public.build_fee_plan(p_enrolment_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
begin
  return app.build_fee_plan_for(p_enrolment_id, app.auth_tenant_id());
end;
$$;

revoke execute on function public.build_fee_plan(uuid) from public, anon;
grant execute on function public.build_fee_plan(uuid) to authenticated;

create or replace function app.tg_enrolment_build_fee_plan()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.build_fee_plan_for(new.id, new.tenant_id);
  return new;
end;
$$;
