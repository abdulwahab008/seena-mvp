-- A student's fee could only be changed one student at a time from their profile. These apply the same
-- change to many students' fee plan lines in one step, through the existing per-line functions so every
-- role, campus and reason check still holds: all lines change or none do.
-- p_approve lets someone who may also approve (owner, super admin) make the change live at once;
-- for anyone else it fails with FORBIDDEN, as decide_fee_plan_override() does.
create or replace function public.bulk_propose_fee_plan_override(
  p_line_ids uuid[], p_new_amount_paisa bigint, p_reason text, p_approve boolean default false
)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if coalesce(cardinality(p_line_ids), 0) = 0 or cardinality(p_line_ids) > 2000 then
    raise exception 'LINES_REQUIRED' using errcode = '22023';
  end if;
  if p_new_amount_paisa is null or p_new_amount_paisa < 0 then
    raise exception 'AMOUNT_INVALID' using errcode = '22023';
  end if;
  foreach v_id in array p_line_ids loop
    perform public.propose_fee_plan_override(v_id, p_new_amount_paisa, p_reason);
    if p_approve then
      perform public.decide_fee_plan_override(v_id, true);
    end if;
  end loop;
  return cardinality(p_line_ids);
end;
$$;

revoke execute on function public.bulk_propose_fee_plan_override(uuid[], bigint, text, boolean) from public, anon;
grant execute on function public.bulk_propose_fee_plan_override(uuid[], bigint, text, boolean) to authenticated;

create or replace function public.bulk_decide_fee_plan_override(p_line_ids uuid[], p_approve boolean)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if coalesce(cardinality(p_line_ids), 0) = 0 or cardinality(p_line_ids) > 2000 then
    raise exception 'LINES_REQUIRED' using errcode = '22023';
  end if;
  foreach v_id in array p_line_ids loop
    perform public.decide_fee_plan_override(v_id, p_approve);
  end loop;
  return cardinality(p_line_ids);
end;
$$;

revoke execute on function public.bulk_decide_fee_plan_override(uuid[], boolean) from public, anon;
grant execute on function public.bulk_decide_fee_plan_override(uuid[], boolean) to authenticated;
