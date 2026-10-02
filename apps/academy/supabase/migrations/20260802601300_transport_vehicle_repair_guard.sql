-- Follow-up to FR-P02/P03: a vehicle that is in the workshop cannot be assigned.
-- The asset/maintenance module (a separate migration) defines
-- public.assert_vehicle_available(vehicle, date), which raises VEHICLE_IN_REPAIR.
-- The assignment path (app.fn_vehicle_assert, called by assign_transport_trip) calls
-- it when it exists, and is unchanged when it does not, so migration order between
-- the two modules does not matter. A Principal's document override does not lift a
-- repair block.
create or replace function app.fn_vehicle_assert(p_vehicle_id uuid, p_on date)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_reason text := app.fn_vehicle_block_reason(p_vehicle_id, p_on);
begin
  if to_regprocedure('public.assert_vehicle_available(uuid,date)') is not null then
    execute 'select public.assert_vehicle_available($1, $2)' using p_vehicle_id, p_on;
  end if;
  if v_reason is null then
    return;
  end if;
  if exists (select 1 from public.transport_vehicle_override o where o.vehicle_id = p_vehicle_id and p_on between o.valid_from and o.valid_to) then
    return;
  end if;
  raise exception 'VEHICLE_BLOCKED: %', v_reason;
end;
$$;
revoke execute on function app.fn_vehicle_assert(uuid, date) from public, anon, authenticated;
