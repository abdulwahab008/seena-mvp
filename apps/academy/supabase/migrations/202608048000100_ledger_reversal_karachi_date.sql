-- A reversal is dated on the school's business day (Asia/Karachi), not the database's UTC date:
-- between 19:00 and 24:00 UTC the two differ, and a receipt cancelled then would not net
-- against the same day's collections (v_daily_collection / v_principal_today use the Karachi date).

alter table public.fee_ledger alter column value_date set default app.fn_karachi_today();

create or replace function public.reverse_ledger_entry(p_ledger_id uuid, p_reason text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entry         public.fee_ledger%rowtype;
  v_new_direction public.fee_ledger_direction;
  v_id            uuid;
begin
  if app.auth_role() not in ('super_admin', 'owner') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 15 then
    raise exception 'REASON_TOO_SHORT' using errcode = '23514';
  end if;

  select * into v_entry from public.fee_ledger where id = p_ledger_id and tenant_id = app.auth_tenant_id();
  if not found then
    raise exception 'LEDGER_ENTRY_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_entry.reversal_of_id is not null then
    raise exception 'CANNOT_REVERSE_A_REVERSAL' using errcode = '55000';
  end if;

  v_new_direction := case v_entry.direction when 'debit' then 'credit'::public.fee_ledger_direction else 'debit'::public.fee_ledger_direction end;

  insert into public.fee_ledger (
    tenant_id, campus_id, enrolment_id, session_id, entry_type, fee_head_id, amount_paisa, direction,
    value_date, source_type, source_id, reason, created_by, reversal_of_id
  ) values (
    v_entry.tenant_id, v_entry.campus_id, v_entry.enrolment_id, v_entry.session_id, 'reversal', v_entry.fee_head_id, v_entry.amount_paisa, v_new_direction,
    app.fn_karachi_today(), 'reversal', p_ledger_id, p_reason, auth.uid(), p_ledger_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.reverse_ledger_entry(uuid, text) from public, anon;
grant execute on function public.reverse_ledger_entry(uuid, text) to authenticated;
