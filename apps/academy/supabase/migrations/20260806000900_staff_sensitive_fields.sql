-- Staff identity numbers, birth dates and bank details are for the people who run HR, not for
-- every colleague.
--
-- The staff register is readable by anyone whose token carries the campus (a class teacher, a
-- nurse, a librarian), because row-level security can only say which rows, not which columns. So
-- any of them could ask the API for `select cnic, dob, passport_no from staff` and get every
-- colleague's national ID number, passport number and date of birth. The directory search
-- already decided who may see these (super admin, owner, principal and HR manager, plus the
-- person themselves); the table did not enforce it. The employee bank detail table had the same
-- hole: its read policy let in any role with the campus, so a teacher could read colleagues' bank
-- names, account numbers and IBANs.
--
--  * The three identity columns of public.staff are no longer readable through the API by anyone:
--    SELECT is granted on every other column instead (so a column added later is private until it
--    is granted on purpose, rather than public until someone notices). Signed-out callers lose
--    the table altogether. Row-level security is unchanged.
--  * public.staff_identity(staff_id) is the one way to read them: for the person themselves, and
--    for super admin / owner (any campus of their school) and principal / HR manager (their own
--    campuses), the same people the directory search already shows them to.
--  * The bank detail read policy loses its "anyone with the campus" clause; payroll roles and the
--    employee keep their access.
--
-- Server-side code (the service role, the SECURITY DEFINER registration and search functions, the
-- database owner) is unaffected; none of the app's pages select these columns.

revoke all on public.staff from anon;

do $$
declare
  v_cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into v_cols
    from information_schema.columns
   where table_schema = 'public'
     and table_name = 'staff'
     and column_name <> all (array['cnic', 'dob', 'passport_no']);

  revoke select on public.staff from authenticated;
  execute format('grant select (%s) on public.staff to authenticated', v_cols);
end $$;

create or replace function public.staff_identity(p_staff_id uuid)
returns table (staff_id uuid, id_document_type public.id_document_type, cnic text, passport_no text, dob date)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  s record;
begin
  select st.id, st.tenant_id, st.campus_id, st.user_id, st.id_document_type, st.cnic, st.passport_no, st.dob
    into s
    from public.staff st
   where st.id = p_staff_id;

  if not found or s.tenant_id is distinct from app.auth_tenant_id() then
    raise exception 'STAFF_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A row with no linked user gives a NULL comparison, which must count as "no", not as "pass".
  if not coalesce(
    s.user_id = (select auth.uid())
    or app.auth_role() in ('super_admin', 'owner')
    or (app.auth_role() in ('principal', 'hr_manager') and s.campus_id = any (app.auth_campus_ids())),
    false
  ) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  return query select s.id, s.id_document_type, s.cnic, s.passport_no, s.dob;
end;
$$;

revoke all on function public.staff_identity(uuid) from public, anon;
grant execute on function public.staff_identity(uuid) to authenticated;

alter policy employee_bank_detail_read on public.employee_bank_detail using (
  tenant_id = app.auth_tenant_id()
  and (
    app.auth_role() in ('super_admin', 'owner', 'hr_manager', 'accountant')
    or exists (
      select 1
        from public.staff s
       where s.id = employee_bank_detail.staff_id
         and s.user_id = (select auth.uid())
    )
  )
);
