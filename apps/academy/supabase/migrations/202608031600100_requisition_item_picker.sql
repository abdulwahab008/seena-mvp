-- FR-R06 follow-up: let a requester pick items for a requisition.
--
-- Anyone who can raise a requisition (every staff role except parent and
-- student: heads of department, teachers, the librarian ...) picks lines from
-- the stock item list, but inv_item is readable only by the stores/finance/
-- leadership roles and carries sale_price and reorder_level, which a requester
-- has no business reading. Widening the row policy would expose those columns,
-- so the picker reads through this narrow definer function that returns just
-- the code and the name of the tenant's active items.

create or replace function public.list_requisition_items()
returns table (id uuid, item_code text, name text)
language sql
stable
security definer
set search_path = ''
as $$
  select i.id, i.item_code, i.name
    from public.inv_item i
   where i.tenant_id = app.auth_tenant_id()
     and i.active
     and app.auth_role() is not null
     and app.auth_role() not in ('parent', 'student')
   order by i.item_code;
$$;
revoke execute on function public.list_requisition_items() from public, anon;
grant execute on function public.list_requisition_items() to authenticated;
