-- FR-N04: fee dues view with pay action.
--
-- v_portal_dues is security_invoker, so a parent only ever sees their own
-- children's challans through the existing fee_challan RLS. The pieces a
-- parent may not read directly (late-fee rules, bank statement lines,
-- gateway configuration) are exposed only as single computed values through
-- helpers that re-check the caller may see that challan.
--
-- "Payment under reconciliation" is the state that stops a parent who paid at
-- the bank counter yesterday from paying online today: a statement line for
-- the challan that has not been posted yet, or a gateway payment awaiting its
-- callback.

create or replace function app.fn_can_view_challan(p_challan_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
      from public.fee_challan c
      join public.enrolment e on e.id = c.enrolment_id
     where c.id = p_challan_id and c.tenant_id = app.auth_tenant_id()
       and (
         (app.auth_role() = 'parent' and e.student_id = any(app.auth_guardian_student_ids()))
         or (app.auth_role() not in ('parent', 'student')
             and (app.auth_role() in ('owner', 'super_admin') or c.campus_id = any(app.auth_campus_ids())))
       )
  );
$$;
grant execute on function app.fn_can_view_challan(uuid) to authenticated;

create or replace function app.fn_challan_under_reconciliation(p_challan_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.fn_can_view_challan(p_challan_id) and exists (
    select 1 from public.fee_challan c
     where c.id = p_challan_id and c.status <> 'paid'
       and (
         exists (select 1 from public.bank_statement_line l
                  where l.tenant_id = c.tenant_id and l.campus_id = c.campus_id and l.challan_ref = c.challan_digits
                    and l.status in ('parsed', 'exception'))
         or exists (select 1 from public.payment_intent i where i.challan_id = c.id and i.status = 'pending')
       )
  );
$$;
grant execute on function app.fn_challan_under_reconciliation(uuid) to authenticated;

-- Accrued late fee as of a date, honouring the campus rule, Sundays and the holiday calendar.
create or replace function public.late_fee_for(p_challan_id uuid, p_as_of date default current_date)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_challan public.fee_challan%rowtype;
begin
  if not app.fn_can_view_challan(p_challan_id) then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  select * into v_challan from public.fee_challan where id = p_challan_id;
  if v_challan.status in ('paid', 'cancelled') then
    return 0;
  end if;
  return app.fn_compute_late_fee(v_challan, p_as_of);
end;
$$;
revoke execute on function public.late_fee_for(uuid, date) from public, anon;
grant execute on function public.late_fee_for(uuid, date) to authenticated;

create or replace function app.fn_enabled_gateways(p_tenant_id uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(gateway order by gateway), '{}'::text[])
    from public.payment_gateway_config
   where tenant_id = p_tenant_id and is_enabled and p_tenant_id = app.auth_tenant_id();
$$;
grant execute on function app.fn_enabled_gateways(uuid) to authenticated;

-- Accrued late fee for the portal view; 0 unless the caller may see the challan.
create or replace function app.fn_portal_late_fee(p_challan_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case when app.fn_can_view_challan(p_challan_id) and c.status in ('unpaid', 'part_paid')
              then app.fn_compute_late_fee(c, current_date) else 0 end
    from public.fee_challan c where c.id = p_challan_id;
$$;
grant execute on function app.fn_portal_late_fee(uuid) to authenticated;

-- Allocations are finance-only under RLS; a parent needs the total, nothing else.
create or replace function app.fn_portal_allocated(p_challan_id uuid)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case when app.fn_can_view_challan(p_challan_id)
              then coalesce((select sum(amount_paisa) from public.fee_payment_allocation where challan_id = p_challan_id), 0)::bigint
              else 0::bigint end;
$$;
grant execute on function app.fn_portal_allocated(uuid) to authenticated;

create view public.v_portal_dues with (security_invoker = true) as
select c.id as challan_id, c.tenant_id, c.campus_id, c.enrolment_id, e.student_id, c.challan_no, c.billing_period,
       c.due_date, c.status, c.net_paisa,
       app.fn_portal_allocated(c.id) as allocated_paisa,
       greatest(c.net_paisa - app.fn_portal_allocated(c.id), 0)::bigint as balance_paisa,
       coalesce(app.fn_portal_late_fee(c.id), 0) as late_fee_paisa,
       (greatest(c.net_paisa - app.fn_portal_allocated(c.id), 0) + coalesce(app.fn_portal_late_fee(c.id), 0))::bigint as total_due_paisa,
       app.fn_challan_under_reconciliation(c.id) as under_reconciliation,
       greatest(current_date - c.due_date, 0) as days_overdue,
       app.fn_enabled_gateways(c.tenant_id) as gateways
  from public.fee_challan c
  join public.enrolment e on e.id = c.enrolment_id
 where c.deleted_at is null and c.status <> 'cancelled';


-- Payload builder without a role check, used only behind an explicit caller check.
create or replace function app.fn_challan_payload(p_challan_id uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path = ''
as $$
declare
  v_challan  public.fee_challan%rowtype;
  v_template public.challan_template%rowtype;
  v_student  record;
  v_lines    jsonb;
  v_logo     jsonb;
  v_arrears  jsonb;
begin
  select * into v_challan from public.fee_challan where id = p_challan_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  select * into v_template from public.challan_template where campus_id = v_challan.campus_id;
  if v_challan.logo_asset_id is not null then
    select jsonb_build_object('asset_id', id, 'storage_path', storage_path) into v_logo
      from public.branding_asset where id = v_challan.logo_asset_id;
  end if;

  select s.name_en, s.gr_number, cl.name_en as class_name, cs.name as section_name
    into v_student
    from public.enrolment e
    join public.student s on s.id = e.student_id
    join public.class_level cl on cl.id = e.class_level_id
    join public.class_section cs on cs.id = e.section_id
   where e.id = v_challan.enrolment_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'head_name', fh.name_en, 'amount_paisa', fcl.amount_paisa,
           'concession_paisa', fcl.concession_paisa, 'net_paisa', fcl.net_paisa, 'line_type', fcl.line_type
         ) order by fh.code), '[]'::jsonb)
    into v_lines
    from public.fee_challan_line fcl
    join public.fee_head fh on fh.id = fcl.fee_head_id
   where fcl.challan_id = p_challan_id;

  -- Resolved against academic_session for the session NAME, not just the
  -- id: "Arrears (2025-26)" is what makes the carried amount answerable
  -- at the counter without a second lookup.
  select coalesce(jsonb_agg(jsonb_build_object(
           'session_id', src ->> 'session_id',
           'session_name', ses.name,
           'amount_paisa', (src ->> 'amount_paisa')::bigint
         )), '[]'::jsonb)
    into v_arrears
    from jsonb_array_elements(v_challan.arrears_source) src
    left join public.academic_session ses on ses.id = (src ->> 'session_id')::uuid;

  return jsonb_build_object(
    'challan_no', v_challan.challan_no,
    'barcode_value', v_challan.challan_no,
    'billing_period', v_challan.billing_period,
    'issue_date', v_challan.issue_date,
    'due_date', v_challan.due_date,
    'student', jsonb_build_object(
      'name_en', v_student.name_en, 'gr_number', v_student.gr_number,
      'class_name', v_student.class_name, 'section_name', v_student.section_name
    ),
    'bank', jsonb_build_object(
      'bank_name', v_template.bank_name, 'bank_account_title', v_template.bank_account_title,
      'bank_account_no', v_template.bank_account_no, 'footer_note_en', v_template.footer_note_en,
      'footer_note_ur', v_template.footer_note_ur
    ),
    'logo', v_logo,
    'lines', v_lines,
    'gross_paisa', v_challan.gross_paisa,
    'concession_paisa', v_challan.concession_paisa,
    'arrears_paisa', v_challan.arrears_paisa,
    'arrears_source', v_arrears,
    'net_paisa', v_challan.net_paisa,
    'copies', jsonb_build_array('bank', 'school', 'student')
  );
end;
$$;
revoke execute on function app.fn_challan_payload(uuid) from public, anon, authenticated;

create or replace function public.build_challan_render_payload(p_challan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return app.fn_challan_payload(p_challan_id);
end;
$$;

create or replace function public.portal_challan_payload(p_challan_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not app.fn_can_view_challan(p_challan_id) then
    raise exception 'CHALLAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  return app.fn_challan_payload(p_challan_id);
end;
$$;
revoke execute on function public.portal_challan_payload(uuid) from public, anon;
grant execute on function public.portal_challan_payload(uuid) to authenticated;
