-- A draft fee structure could only have lines added and their amount changed: a line added with the wrong
-- frequency or fee head could not be fixed or removed, and setting one fee for a range of classes
-- (e.g. Class 1-5 at PKR 3,000) meant adding each class by hand and failing on classes that already had it.
-- set_structure_lines() adds or updates one fee head for many classes at once; update_structure_line()
-- changes a line's amount, frequency and months; remove_structure_line() deletes it. Drafts only.

create or replace function app.fn_draft_structure_for_edit(p_structure_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_status public.fee_structure_status;
begin
  if app.auth_role() not in ('super_admin', 'owner', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select status into v_status from public.fee_structure where id = p_structure_id and tenant_id = app.auth_tenant_id();
  if v_status is null then
    raise exception 'STRUCTURE_NOT_FOUND' using errcode = 'P0002';
  end if;
  if v_status <> 'draft' then
    raise exception 'STRUCTURE_NOT_DRAFT' using errcode = '55000';
  end if;
end;
$$;

revoke execute on function app.fn_draft_structure_for_edit(uuid) from public, anon;

create or replace function public.set_structure_lines(
  p_structure_id uuid, p_class_ids uuid[], p_fee_head_id uuid, p_amount_paisa bigint, p_frequency public.fee_frequency,
  p_group_code text default null, p_billing_month_mask smallint default 4095
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_added   int;
  v_updated int;
begin
  perform app.fn_draft_structure_for_edit(p_structure_id);
  if coalesce(cardinality(p_class_ids), 0) = 0 then
    raise exception 'CLASSES_REQUIRED' using errcode = '22023';
  end if;
  if exists (
    select 1 from unnest(p_class_ids) c(id)
     where not exists (select 1 from public.class_level where id = c.id and tenant_id = app.auth_tenant_id())
  ) then
    raise exception 'CLASS_LEVEL_NOT_FOUND' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.fee_head where id = p_fee_head_id and tenant_id = app.auth_tenant_id()) then
    raise exception 'FEE_HEAD_NOT_FOUND' using errcode = 'P0002';
  end if;

  with upserted as (
    insert into public.fee_structure_line (structure_id, class_id, group_code, fee_head_id, amount_paisa, frequency, billing_month_mask)
    select distinct p_structure_id, c.id, nullif(btrim(p_group_code), ''), p_fee_head_id, p_amount_paisa, p_frequency, p_billing_month_mask
      from unnest(p_class_ids) c(id)
    on conflict (structure_id, class_id, coalesce(group_code, ''), fee_head_id)
      do update set amount_paisa = excluded.amount_paisa, frequency = excluded.frequency, billing_month_mask = excluded.billing_month_mask
    returning (xmax = 0) as inserted
  )
  select count(*) filter (where inserted), count(*) filter (where not inserted) into v_added, v_updated from upserted;

  return jsonb_build_object('added', v_added, 'updated', v_updated);
end;
$$;

revoke execute on function public.set_structure_lines(uuid, uuid[], uuid, bigint, public.fee_frequency, text, smallint) from public, anon;
grant execute on function public.set_structure_lines(uuid, uuid[], uuid, bigint, public.fee_frequency, text, smallint) to authenticated;

create or replace function public.update_structure_line(
  p_line_id uuid, p_amount_paisa bigint, p_frequency public.fee_frequency, p_billing_month_mask smallint
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_structure_id uuid;
begin
  select structure_id into v_structure_id from public.fee_structure_line where id = p_line_id;
  if v_structure_id is null then
    raise exception 'STRUCTURE_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_draft_structure_for_edit(v_structure_id);

  update public.fee_structure_line
     set amount_paisa = p_amount_paisa, frequency = p_frequency, billing_month_mask = p_billing_month_mask
   where id = p_line_id;
end;
$$;

revoke execute on function public.update_structure_line(uuid, bigint, public.fee_frequency, smallint) from public, anon;
grant execute on function public.update_structure_line(uuid, bigint, public.fee_frequency, smallint) to authenticated;

create or replace function public.remove_structure_line(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_structure_id uuid;
begin
  select structure_id into v_structure_id from public.fee_structure_line where id = p_line_id;
  if v_structure_id is null then
    raise exception 'STRUCTURE_LINE_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform app.fn_draft_structure_for_edit(v_structure_id);

  delete from public.fee_structure_line where id = p_line_id;
end;
$$;

revoke execute on function public.remove_structure_line(uuid) from public, anon;
grant execute on function public.remove_structure_line(uuid) to authenticated;
