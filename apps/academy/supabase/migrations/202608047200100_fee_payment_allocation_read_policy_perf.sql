-- fee_payment_allocation_read was `payment_id IN (select id from fee_payment where <scope>)`.
-- The sub-select is uncorrelated, so Postgres hashes it: every read of an allocation (the
-- student page lists them) scans ALL of the tenant's payments first. On a database with
-- hundreds of thousands of payments that is a ~10 s sequential scan and the request hits the
-- statement timeout, so the payment list on /students/[id] never shows the payment.
--
-- Same predicate, written as a correlated EXISTS so the planner does a primary-key probe on
-- fee_payment per allocation row (and evaluates the auth lookups once, as init-plans).
drop policy if exists fee_payment_allocation_read on public.fee_payment_allocation;
create policy fee_payment_allocation_read on public.fee_payment_allocation
  for select to authenticated
  using (
    exists (
      select 1
        from public.fee_payment p
       where p.id = fee_payment_allocation.payment_id
         and p.tenant_id = (select app.auth_tenant_id())
         and ((select app.auth_role()) in ('super_admin', 'owner') or p.campus_id = any (app.auth_campus_ids()))
    )
  );
