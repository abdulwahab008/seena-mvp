-- Schools can add the bank account their fee collections land in. Until now
-- campus_bank_account had no write path at all, so Bank Statements had nothing
-- to import against. Same roles that assign a mapping profile to an account.

create or replace function public.add_campus_bank_account(p_campus_id uuid, p_bank_name text, p_title text, p_account_no text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if app.auth_role() not in ('accountant', 'owner', 'super_admin') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.campus c
     where c.id = p_campus_id and c.tenant_id = app.auth_tenant_id()
       and (app.auth_role() in ('owner', 'super_admin') or c.id = any (app.auth_campus_ids()))
  ) then
    raise exception 'CAMPUS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if coalesce(btrim(p_bank_name), '') = '' or coalesce(btrim(p_title), '') = '' or coalesce(btrim(p_account_no), '') = '' then
    raise exception 'BANK_ACCOUNT_FIELDS_REQUIRED' using errcode = '22023';
  end if;
  if exists (select 1 from public.campus_bank_account where campus_id = p_campus_id and account_no = btrim(p_account_no)) then
    raise exception 'BANK_ACCOUNT_EXISTS' using errcode = '23505';
  end if;

  insert into public.campus_bank_account (campus_id, bank_name, title, account_no)
  values (p_campus_id, btrim(p_bank_name), btrim(p_title), btrim(p_account_no))
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.add_campus_bank_account(uuid, text, text, text) from public, anon;
grant execute on function public.add_campus_bank_account(uuid, text, text, text) to authenticated;
