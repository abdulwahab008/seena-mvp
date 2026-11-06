-- Parent and student accounts never read the cash-counter tables; keep them behind the portal-role
-- boundary like every other staff-only table.
select app.fn_block_portal_roles(t::regclass)
  from unnest(array['public.cash_counter', 'public.cash_counter_session', 'public.cash_denomination_count']) t;
