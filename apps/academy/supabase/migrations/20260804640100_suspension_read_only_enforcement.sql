-- FR-D15 follow-up: enforce the read-only effective role of a suspended staff
-- member across the product.
--
-- FR-D15 AC3: during a suspension "the staff member's effective role is
-- read-only". effective_app_role() reported that but nothing enforced it, so a
-- suspended teacher could still mark attendance, enter marks, post homework,
-- approve leave, issue certificates or collect fees.
--
-- Enforcement is ONE shared guard rather than a check pasted into hundreds of
-- RPCs and policies:
--
--   app.is_caller_suspended()            the single question "is the signed-in
--                                        user suspended today?" (same rule as
--                                        is_staff_suspended: in-window and not
--                                        superseded by a correction/reinstatement)
--   app.assert_not_suspended()           raises STAFF_SUSPENDED (42501); callable
--                                        from any future RPC
--   app.tg_block_suspended_write()       statement-level BEFORE trigger wrapping
--                                        the assertion
--
-- A table trigger is the choke point because it fires for every write path -
-- direct PostgREST DML under RLS and SECURITY DEFINER RPCs alike (RLS is
-- bypassed by definer functions, triggers are not) - while reads, which the
-- suspended person still needs (own timetable, own payslip), are untouched.
-- System work (cron, service role, migrations) carries no end-user uid and is
-- never blocked, so the daily jobs and the substitution engine keep running.
--
-- Guarded: student attendance, mark entry, homework, leave decisions, certificate
-- issuance, fee collection, substitution assignment. Staff submitting their own
-- leave is not blocked (the guard is UPDATE/DELETE-only on the leave tables,
-- where decisions happen).

create index if not exists idx_staff_user_id on public.staff (user_id) where user_id is not null;

create or replace function app.is_caller_suspended()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select auth.uid()) is not null and exists (
    select 1
      from public.staff st
      join public.staff_suspension s on s.staff_id = st.id
     where st.user_id = (select auth.uid())
       and app.fn_karachi_today() between s.from_date and s.to_date
       and not exists (select 1 from public.staff_disciplinary succ where succ.supersedes_id = s.disciplinary_id)
  ), false);
$$;
revoke execute on function app.is_caller_suspended() from public, anon;
grant execute on function app.is_caller_suspended() to authenticated;

create or replace function app.assert_not_suspended()
returns void
language plpgsql
stable
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
set search_path = ''
as $$
begin
  perform app.assert_not_suspended();
  return null;
end;
$$;
revoke execute on function app.tg_block_suspended_write() from public, anon;

do $$
declare
  t text;
begin
  -- every write
  foreach t in array array[
    'attendance_day', 'attendance_period', 'attendance_correction_request',
    'mark_entry', 'mark_entry_batch', 'mark_moderation',
    'homework', 'homework_feedback_history',
    'certificate_issue', 'certificate_request', 'staff_certificate',
    'fee_payment', 'fee_receipt', 'timetable_substitution'
  ] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_block_suspended_write on public.%I', t);
      execute format('create trigger trg_block_suspended_write before insert or update or delete on public.%I '
                     'for each statement execute function app.tg_block_suspended_write()', t);
    end if;
  end loop;
  -- decisions only (submitting one's own request stays possible)
  foreach t in array array['leave_application', 'leave_approval_step', 'student_leave_application'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_block_suspended_write on public.%I', t);
      execute format('create trigger trg_block_suspended_write before update or delete on public.%I '
                     'for each statement execute function app.tg_block_suspended_write()', t);
    end if;
  end loop;
end;
$$;
