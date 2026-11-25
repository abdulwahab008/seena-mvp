-- Where each staff member's salary is paid, so the payroll bank file can carry
-- the account. Kept off the staff row: staff is read widely, an account number
-- is not. Readable by payroll roles and by the staff member; written only
-- through set_staff_bank_account.

create table public.staff_bank_account (
  staff_id      uuid primary key references public.staff(id) on delete cascade,
  tenant_id     uuid not null references public.tenant(id) on delete cascade,
  bank_name     text not null check (char_length(btrim(bank_name)) between 2 and 80),
  account_title text not null check (char_length(btrim(account_title)) between 2 and 120),
  account_no    text not null check (account_no ~ '^(PK[0-9]{2}[A-Z]{4}[0-9]{16}|[0-9]{6,20})$'),
  updated_by    uuid references auth.users(id),
  updated_at    timestamptz not null default now()
);
create index idx_staff_bank_account_tenant on public.staff_bank_account (tenant_id);

create trigger staff_bank_account_audit after insert or update or delete on public.staff_bank_account
  for each row execute function app.tg_audit_row();

alter table public.staff_bank_account enable row level security;
create policy portal_roles_blocked on public.staff_bank_account as restrictive for all to authenticated
  using ((select app.auth_role()) not in ('parent', 'student'))
  with check ((select app.auth_role()) not in ('parent', 'student'));
create policy staff_bank_account_read on public.staff_bank_account
  for select to authenticated
  using (
    tenant_id = (select app.auth_tenant_id())
    and (
      (select app.auth_role()) in ('super_admin', 'owner', 'hr_manager', 'accountant')
      or exists (select 1 from public.staff s where s.id = staff_bank_account.staff_id and s.user_id = (select auth.uid()))
    )
  );

-- IBAN (PK + 2 check digits + 4-letter bank code + 16 digits) or a plain 6-20 digit account number;
-- spaces and dashes are dropped and letters upper-cased before checking.
create or replace function public.set_staff_bank_account(p_staff_id uuid, p_bank_name text, p_account_title text, p_account_no text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_no     text := upper(regexp_replace(coalesce(p_account_no, ''), '[\s-]', '', 'g'));
begin
  if app.auth_role() not in ('super_admin', 'owner', 'hr_manager', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if not exists (select 1 from public.staff where id = p_staff_id and tenant_id = v_tenant) then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;
  if coalesce(btrim(p_bank_name), '') = '' or coalesce(btrim(p_account_title), '') = '' then
    raise exception 'BANK_FIELDS_REQUIRED' using errcode = '22023';
  end if;
  if v_no !~ '^(PK[0-9]{2}[A-Z]{4}[0-9]{16}|[0-9]{6,20})$' then
    raise exception 'ACCOUNT_NO_INVALID' using errcode = '22023';
  end if;

  insert into public.staff_bank_account (staff_id, tenant_id, bank_name, account_title, account_no, updated_by, updated_at)
  values (p_staff_id, v_tenant, btrim(p_bank_name), btrim(p_account_title), v_no, (select auth.uid()), now())
  on conflict (staff_id) do update
    set bank_name = excluded.bank_name, account_title = excluded.account_title, account_no = excluded.account_no,
        updated_by = excluded.updated_by, updated_at = excluded.updated_at;
end;
$$;
revoke execute on function public.set_staff_bank_account(uuid, text, text, text) from public, anon;
grant execute on function public.set_staff_bank_account(uuid, text, text, text) to authenticated;
