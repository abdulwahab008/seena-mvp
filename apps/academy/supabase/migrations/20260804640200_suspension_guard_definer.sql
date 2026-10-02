-- The suspension write guard must not depend on the invoking role's EXECUTE
-- rights: service_role / postgres-with-forged-claims paths (and any role not
-- granted app functions) write to guarded tables too, and must reach the guard
-- (which then finds no suspended end-user) instead of failing on "permission
-- denied for function". Run both guard functions as their owner.

create or replace function app.assert_not_suspended()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.is_caller_suspended() then
    raise exception 'STAFF_SUSPENDED' using errcode = '42501',
      detail = 'Your account is read-only while a suspension is in force.';
  end if;
end;
$$;
revoke execute on function app.assert_not_suspended() from public, anon;
grant execute on function app.assert_not_suspended() to authenticated;

create or replace function app.tg_block_suspended_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.assert_not_suspended();
  return null;
end;
$$;
revoke execute on function app.tg_block_suspended_write() from public, anon;
