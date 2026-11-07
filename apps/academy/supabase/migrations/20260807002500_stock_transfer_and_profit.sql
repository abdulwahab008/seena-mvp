-- Stores: move stock between stores, and see profit on what the shop sold.
--
-- A transfer is an issue out of one store and a receipt into the other,
-- posted together through the stock ledger at the item's average purchase
-- cost, both pointing at the same transfer id. Profit uses the same average
-- cost: everything received with a cost, weighted by quantity.

create or replace function app.fn_item_average_cost(p_item_id uuid)
returns bigint
language sql
stable
set search_path = ''
as $$
  select coalesce(round(sum(qty * unit_cost) / nullif(sum(qty), 0))::bigint, 0)
    from public.inv_stock_movement
   where item_id = p_item_id and movement_type = 'receipt' and unit_cost is not null and qty > 0;
$$;
revoke execute on function app.fn_item_average_cost(uuid) from public, anon, authenticated;

create or replace function public.transfer_stock(p_from_store_id uuid, p_to_store_id uuid, p_item_id uuid, p_qty numeric)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ref  uuid := gen_random_uuid();
  v_cost bigint;
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  if p_from_store_id = p_to_store_id then
    raise exception 'SAME_STORE' using errcode = '22023';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception 'QTY_INVALID' using errcode = '22023';
  end if;
  if (select count(*) from public.inv_store where id in (p_from_store_id, p_to_store_id) and tenant_id = app.auth_tenant_id()) <> 2 then
    raise exception 'STORE_NOT_FOUND' using errcode = 'P0002';
  end if;
  v_cost := app.fn_item_average_cost(p_item_id);
  perform public.post_stock_movement(p_from_store_id, p_item_id, 'issue', p_qty, v_cost, null, 'stock_transfer', v_ref);
  perform public.post_stock_movement(p_to_store_id, p_item_id, 'receipt', p_qty, v_cost, null, 'stock_transfer', v_ref);
  return v_ref;
end;
$$;
revoke execute on function public.transfer_stock(uuid, uuid, uuid, numeric) from public, anon;
grant execute on function public.transfer_stock(uuid, uuid, uuid, numeric) to authenticated;

-- Per item between two dates: quantity sold net of returns, revenue, cost at
-- average purchase cost, and profit.
create or replace function public.inventory_profit(p_from date, p_to date)
returns table (item_id uuid, item_code text, name text, qty_sold numeric, revenue_paisa bigint, cost_paisa bigint, profit_paisa bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'principal', 'vice_principal', 'accountant') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return query
    with sold as (
      select l.item_id,
             sum(case when s.doc_type = 'sale' then l.qty else -l.qty end) as qty,
             sum(case when s.doc_type = 'sale' then l.amount else -l.amount end) as revenue
        from public.inv_sale_line l
        join public.inv_sale s on s.id = l.sale_id
       where s.tenant_id = app.auth_tenant_id()
         and (s.sold_at at time zone 'Asia/Karachi')::date between p_from and p_to
         and (app.auth_role() in ('super_admin', 'owner') or s.campus_id = any (app.auth_campus_ids()))
       group by l.item_id
    )
    select i.id, i.item_code, i.name, x.qty, x.revenue::bigint,
           round(x.qty * app.fn_item_average_cost(i.id))::bigint,
           (x.revenue - round(x.qty * app.fn_item_average_cost(i.id)))::bigint
      from sold x
      join public.inv_item i on i.id = x.item_id
     order by x.revenue desc;
end;
$$;
revoke execute on function public.inventory_profit(date, date) from public, anon;
grant execute on function public.inventory_profit(date, date) to authenticated;
