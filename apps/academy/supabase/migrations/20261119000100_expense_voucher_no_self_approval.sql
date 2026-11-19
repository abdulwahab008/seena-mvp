-- A Principal or Vice Principal could raise an expense voucher and then approve it themselves,
-- defeating the approval chain the amount bands route it through. Someone other than the person
-- who raised a voucher now has to decide it. Owners and Super Admins keep deciding their own:
-- there is nobody above them to route to, and blocking them would lock single-owner schools.

create or replace function public.decide_expense_voucher(
  p_voucher_id uuid,
  p_decision   text,
  p_reason     text default null,
  p_request_ip text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant_id uuid := app.auth_tenant_id();
  v_role      text := app.auth_role();
  v_uid       uuid := (select auth.uid());
  v_voucher   public.expense_voucher%rowtype;
  v_reason    text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if p_decision not in ('approved', 'rejected') then
    raise exception 'DECISION_INVALID' using errcode = '22023';
  end if;
  if v_role not in ('super_admin', 'owner', 'principal', 'vice_principal') then
    raise exception 'FORBIDDEN'
      using errcode = '42501', hint = 'Only a Vice Principal, Principal, Owner or Super Admin decides a voucher.';
  end if;

  select * into v_voucher from public.expense_voucher
   where id = p_voucher_id and tenant_id = v_tenant_id
   for update;
  if not found then
    raise exception 'VOUCHER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_role not in ('super_admin', 'owner') and not (v_voucher.campus_id = any(app.auth_campus_ids())) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if v_voucher.status <> 'pending_approval' then
    raise exception 'VOUCHER_NOT_PENDING'
      using errcode = '55000',
            detail = format('status=%s', v_voucher.status),
            hint = 'Only a voucher waiting in the queue can be decided.';
  end if;

  if v_voucher.created_by = v_uid and v_role not in ('super_admin', 'owner') then
    raise exception 'SELF_APPROVAL_NOT_ALLOWED'
      using errcode = '42501',
            hint = 'A voucher you raised has to be decided by someone else.';
  end if;

  -- AC1's routing, enforced on the way in as well as on the way out: a
  -- Vice Principal cannot sign off a voucher the bands routed to the Owner.
  if app.fn_expense_role_rank(v_role::public.app_role)
     < app.fn_expense_role_rank(v_voucher.required_approver_role) then
    raise exception 'APPROVER_RANK_INSUFFICIENT'
      using errcode = '42501',
            detail = format('required=%s actual=%s', v_voucher.required_approver_role, v_role),
            hint = 'This voucher is above your approval limit.';
  end if;

  -- AC2. Also a CHECK constraint on the row, so no path can write a short
  -- one; this is the message a person reads.
  if p_decision = 'rejected' and length(coalesce(v_reason, '')) < 10 then
    raise exception 'REJECTION_REASON_TOO_SHORT'
      using errcode = '23514',
            hint = 'A rejection has to say why, in at least 10 characters.';
  end if;

  insert into public.expense_voucher_approval (
    tenant_id, voucher_id, approver_id, approver_role, decision, reason, request_ip
  ) values (
    v_tenant_id, p_voucher_id, v_uid, v_role::public.app_role,
    p_decision::public.expense_approval_decision, v_reason, app.fn_parse_request_ip(p_request_ip)
  );

  update public.expense_voucher
     set status = p_decision::public.expense_voucher_status
   where id = p_voucher_id;

  return jsonb_build_object(
    'voucher_id', p_voucher_id,
    'status',     p_decision,
    'approver_role', v_role,
    'reason',     v_reason
  );
end;
$$;

revoke execute on function public.decide_expense_voucher(uuid, text, text, text) from public, anon;
grant execute on function public.decide_expense_voucher(uuid, text, text, text) to authenticated;
