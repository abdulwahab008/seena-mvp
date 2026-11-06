-- The cash-counter (FR-K18) and payslip (FR-L08) tables were added after the portal-role boundary
-- and missed its restrictive policy. Parent and student accounts never read either.
select app.fn_block_portal_roles(t::regclass)
  from unnest(array['public.cash_counter', 'public.cash_counter_session', 'public.cash_denomination_count', 'public.payslip', 'public.payslip_denied_access']) t;
