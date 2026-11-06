-- Parent and student accounts never read payslips or the denied-access log; keep both behind the
-- portal-role boundary like every other staff-only table.
select app.fn_block_portal_roles(t::regclass)
  from unnest(array['public.payslip', 'public.payslip_denied_access']) t;
