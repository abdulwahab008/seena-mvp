-- app.fn_export_fee_collection filtered `p.tenant_id = app.auth_tenant_id()` directly. That function is
-- not inlined into a constant: it runs assert_claims_fresh() / assert_impersonation_live() (a query each),
-- so the seq scan over fee_payment evaluated it once per ROW. On a database with 225k payments one 5,000-row
-- page took ~11 s, the export worker hit statement_timeout on every page and the job went failed after its
-- 3 attempts (the 45,000-row export e2e and the branded PDF report never completed).
--
-- Same query, with the tenant resolved once as an init-plan, plus an index that serves the
-- (tenant, value_date, id) ordering the paging uses.
create index if not exists idx_fee_payment_tenant_value_date
  on public.fee_payment (tenant_id, value_date, id);

create or replace function app.fn_export_fee_collection(p_params jsonb, p_offset integer, p_limit integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if app.auth_role() not in ('owner', 'super_admin', 'accountant', 'principal') then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(r) from (
      select p.value_date, st.gr_number, st.name_en as student_name, p.amount_paisa, p.mode::text as mode, p.reference_no
        from public.fee_payment p
        join public.enrolment e on e.id = p.enrolment_id
        join public.student st on st.id = e.student_id
       where p.tenant_id = (select app.auth_tenant_id()) and p.campus_id = any(app.auth_campus_ids())
         and (p_params ->> 'from' is null or p.value_date >= (p_params ->> 'from')::date)
         and (p_params ->> 'to' is null or p.value_date <= (p_params ->> 'to')::date)
       order by p.value_date, p.id
       offset greatest(p_offset, 0) limit least(greatest(p_limit, 1), 10000)
    ) r
  ), '[]'::jsonb);
end;
$$;
revoke execute on function app.fn_export_fee_collection(jsonb, integer, integer) from public, anon, authenticated;
