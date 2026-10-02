-- FR-D07: manual daily staff attendance marking, closing out the scope
-- cut noted in FR-D11's migration. staff_attendance itself already exists
-- (FR-D11 needed somewhere to write leave-sourced rows) — this migration
-- adds the bulk-marking RPC and the audit trigger that table never got.
--
-- seed_staff_attendance_from_leave() from the FR's own Supabase Objects
-- list is NOT built: FR-D11/D12's approval path already writes on_leave
-- rows directly into staff_attendance for the full leave date range at
-- approval time, not on demand when a marking sheet is opened — by the
-- time a sheet is opened for a given day, any approved leave for that day
-- is already sitting in the table with source='leave'. A separate seed
-- step would just be re-deriving data that's already there.

create trigger staff_attendance_audit after insert or update or delete on public.staff_attendance
  for each row execute function app.tg_audit_row();

create or replace function public.mark_staff_attendance_bulk(p_campus_id uuid, p_date date, p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row              jsonb;
  v_staff_id         uuid;
  v_status           public.attendance_status;
  v_remarks          text;
  v_existing_source  public.attendance_source;
  v_written_count    int := 0;
  v_locked_staff_ids uuid[] := '{}';
begin
  if app.auth_role() not in ('super_admin', 'owner', 'principal', 'hr_manager') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;

  -- A 7-day correction window for HR Manager; Principal/Owner/Super Admin
  -- are not bound by it. Every write either way lands in audit_log via
  -- the trigger above.
  if app.auth_role() = 'hr_manager' and p_date < current_date - 7 then
    raise exception 'CORRECTION_WINDOW_EXPIRED' using errcode = '23514';
  end if;

  -- One transaction, one RPC call for the whole campus — never one row
  -- per tap, or a flaky mobile connection leaves the register half
  -- written.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_staff_id := (v_row ->> 'staff_id')::uuid;
    v_status   := (v_row ->> 'status')::public.attendance_status;
    v_remarks  := v_row ->> 'remarks';

    select source into v_existing_source
      from public.staff_attendance
     where staff_id = v_staff_id and att_date = p_date;

    -- Source precedence: leave > biometric > manual. A clerk cannot mark
    -- an approved-leave teacher absent and trigger a wrong pay deduction
    -- — the row is skipped (not written), not silently overwritten, and
    -- reported back so the sheet UI can show which rows were locked.
    if v_existing_source = 'leave' and v_status not in ('on_leave', 'half_day') then
      v_locked_staff_ids := v_locked_staff_ids || v_staff_id;
      continue;
    end if;

    insert into public.staff_attendance (tenant_id, campus_id, staff_id, att_date, status, source, marked_by, remarks)
    values (app.auth_tenant_id(), p_campus_id, v_staff_id, p_date, v_status, 'manual', auth.uid(), v_remarks)
    on conflict (staff_id, att_date) do update
       set status = excluded.status, source = 'manual', marked_by = excluded.marked_by, remarks = excluded.remarks, marked_at = now()
     where public.staff_attendance.source <> 'leave';

    v_written_count := v_written_count + 1;
  end loop;

  return jsonb_build_object('written', v_written_count, 'locked_staff_ids', to_jsonb(v_locked_staff_ids));
end;
$$;

revoke execute on function public.mark_staff_attendance_bulk(uuid, date, jsonb) from public, anon;
grant execute on function public.mark_staff_attendance_bulk(uuid, date, jsonb) to authenticated;
