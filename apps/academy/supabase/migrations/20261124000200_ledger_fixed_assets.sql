-- Fixed assets reach the general ledger.
--
--   asset registered             Dr 1500 Furniture and equipment   Cr 1010 Bank   (the register is the purchase record)
--   capital repair               Dr 1500                           Cr 1010
--   monthly depreciation         Dr 5700 Depreciation              Cr 1590 Accumulated depreciation
--   disposal                     Dr 1590 accumulated, Dr 1000 proceeds, Cr 1500 cost;
--                                the difference to 4800 Gain or 5800 Loss on disposal
--
-- A capital repair raises asset.capitalised_cost and posts on its own, so the
-- purchase posts the cost less capital repairs; the backfill then never counts
-- an improvement twice. Depreciation is dated the last day of its month, so a
-- catch-up run posts each missed month in its own month.
--
-- Four accounts are added to every chart that lacks them, and to new charts.

alter table public.journal_entry drop constraint journal_entry_source_kind_check;
alter table public.journal_entry add constraint journal_entry_source_kind_check
  check (source_kind in ('fee_payment', 'expense_voucher', 'payroll_accrual', 'payroll_payment', 'inv_sale', 'petty_cash', 'opening', 'year_close',
                         'staff_loan', 'staff_loan_recovery', 'asset_purchase', 'asset_improvement', 'asset_depreciation', 'asset_disposal'));

insert into public.gl_account (tenant_id, code, name, type)
select t.tenant_id, c.code, c.name, c.type::public.gl_account_type
  from (select distinct tenant_id from public.gl_account) t
 cross join (values ('1590', 'Accumulated depreciation', 'asset'), ('4800', 'Gain on disposal of assets', 'income'),
                    ('5700', 'Depreciation', 'expense'), ('5800', 'Loss on disposal of assets', 'expense')) as c(code, name, type)
on conflict (tenant_id, code) do nothing;

create or replace function public.ensure_chart_of_accounts()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n int;
begin
  perform app.fn_assert_accountant();
  if exists (select 1 from public.gl_account where tenant_id = app.auth_tenant_id()) then
    return 0;
  end if;
  insert into public.gl_account (tenant_id, code, name, type)
  select app.auth_tenant_id(), c.code, c.name, c.type::public.gl_account_type
    from (values
      ('1000', 'Cash in hand', 'asset'), ('1010', 'Bank', 'asset'), ('1100', 'Fees receivable', 'asset'),
      ('1200', 'Stock (uniforms, books)', 'asset'), ('1300', 'Advances to staff', 'asset'), ('1500', 'Furniture and equipment', 'asset'),
      ('1590', 'Accumulated depreciation', 'asset'),
      ('2000', 'Accounts payable', 'liability'), ('2100', 'Salaries payable', 'liability'), ('2200', 'Fees received in advance', 'liability'),
      ('2300', 'Security deposits held', 'liability'), ('2400', 'Tax and EOBI payable', 'liability'),
      ('3000', 'Owner''s capital', 'equity'), ('3100', 'Retained earnings', 'equity'),
      ('4000', 'Tuition fee income', 'income'), ('4100', 'Admission fee income', 'income'), ('4200', 'Transport fee income', 'income'),
      ('4300', 'Sales of uniforms and books', 'income'), ('4800', 'Gain on disposal of assets', 'income'), ('4900', 'Other income', 'income'),
      ('5000', 'Salaries', 'expense'), ('5100', 'Utilities', 'expense'), ('5200', 'Rent', 'expense'),
      ('5300', 'Stationery and supplies', 'expense'), ('5400', 'Repairs and maintenance', 'expense'),
      ('5500', 'Transport running costs', 'expense'), ('5600', 'Cost of goods sold', 'expense'), ('5700', 'Depreciation', 'expense'),
      ('5800', 'Loss on disposal of assets', 'expense'), ('5900', 'Other expenses', 'expense')
    ) as c(code, name, type);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function app.fn_gl_post_asset_purchase(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  a public.asset%rowtype;
  v_cost bigint;
begin
  select * into a from public.asset where id = p_id;
  if not found then
    return null;
  end if;
  select a.capitalised_cost - coalesce(sum(m.cost), 0) into v_cost
    from public.asset_maintenance m where m.asset_id = p_id and m.is_capitalised;
  return app.fn_gl_post_system(a.tenant_id, a.purchased_on, 'Asset bought · ' || a.tag_no || ' ' || a.name, 'asset_purchase', a.id,
    jsonb_build_array(jsonb_build_object('code', '1500', 'debit', v_cost), jsonb_build_object('code', '1010', 'credit', v_cost)));
end;
$$;

create or replace function app.fn_gl_post_asset_improvement(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  m public.asset_maintenance%rowtype;
  v_tag text;
begin
  select * into m from public.asset_maintenance where id = p_id;
  if not found or not m.is_capitalised then
    return null;
  end if;
  select tag_no into v_tag from public.asset where id = m.asset_id;
  return app.fn_gl_post_system(m.tenant_id, m.reported_on, 'Capital repair · ' || v_tag, 'asset_improvement', m.id,
    jsonb_build_array(jsonb_build_object('code', '1500', 'debit', m.cost), jsonb_build_object('code', '1010', 'credit', m.cost)));
end;
$$;

create or replace function app.fn_gl_post_asset_depreciation(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.asset_depreciation_entry%rowtype;
  v_tag text;
begin
  select * into e from public.asset_depreciation_entry where id = p_id;
  if not found then
    return null;
  end if;
  select tag_no into v_tag from public.asset where id = e.asset_id;
  return app.fn_gl_post_system(e.tenant_id, (e.period + interval '1 month - 1 day')::date,
    'Depreciation ' || to_char(e.period, 'Mon YYYY') || ' · ' || v_tag, 'asset_depreciation', e.id,
    jsonb_build_array(jsonb_build_object('code', '5700', 'debit', e.amount), jsonb_build_object('code', '1590', 'credit', e.amount)));
end;
$$;

create or replace function app.fn_gl_post_asset_disposal(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  d public.asset_disposal%rowtype;
  a public.asset%rowtype;
begin
  select * into d from public.asset_disposal where id = p_id;
  if not found then
    return null;
  end if;
  select * into a from public.asset where id = d.asset_id;
  return app.fn_gl_post_system(d.tenant_id, d.disposed_on,
    case when d.written_off then 'Asset written off · ' else 'Asset sold · ' end || a.tag_no || ' ' || a.name, 'asset_disposal', d.id,
    jsonb_build_array(
      jsonb_build_object('code', '1590', 'debit', a.capitalised_cost - d.nbv_at_disposal, 'memo', 'Accumulated depreciation'),
      jsonb_build_object('code', '1000', 'debit', d.proceeds, 'memo', 'Proceeds'),
      jsonb_build_object('code', '5800', 'debit', greatest(-d.gain_loss, 0), 'memo', 'Loss on disposal'),
      jsonb_build_object('code', '1500', 'credit', a.capitalised_cost, 'memo', 'Cost'),
      jsonb_build_object('code', '4800', 'credit', greatest(d.gain_loss, 0), 'memo', 'Gain on disposal')));
end;
$$;

revoke execute on function app.fn_gl_post_asset_purchase(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_asset_improvement(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_asset_depreciation(uuid) from public, anon, authenticated;
revoke execute on function app.fn_gl_post_asset_disposal(uuid) from public, anon, authenticated;

create or replace function app.tg_gl_post()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  case tg_table_name
    when 'fee_payment' then perform app.fn_gl_post_fee_payment(new.id);
    when 'expense_voucher' then perform app.fn_gl_post_expense_voucher(new.id);
    when 'payroll_run' then perform app.fn_gl_post_payroll(new.id);
    when 'inv_sale' then perform app.fn_gl_post_inv_sale(new.id);
    when 'petty_cash_txn' then perform app.fn_gl_post_petty_cash(new.id);
    when 'staff_loan' then perform app.fn_gl_post_staff_loan(new.id);
    when 'staff_loan_recovery' then perform app.fn_gl_post_staff_loan_recovery(new.id);
    when 'asset' then perform app.fn_gl_post_asset_purchase(new.id);
    when 'asset_maintenance' then perform app.fn_gl_post_asset_improvement(new.id);
    when 'asset_depreciation_entry' then perform app.fn_gl_post_asset_depreciation(new.id);
    when 'asset_disposal' then perform app.fn_gl_post_asset_disposal(new.id);
  end case;
  return null;
end;
$$;

create trigger asset_gl_post after insert on public.asset
  for each row execute function app.tg_gl_post();
create trigger asset_maintenance_gl_post after insert on public.asset_maintenance
  for each row when (new.is_capitalised) execute function app.tg_gl_post();
create trigger asset_depreciation_entry_gl_post after insert on public.asset_depreciation_entry
  for each row execute function app.tg_gl_post();
create trigger asset_disposal_gl_post after insert on public.asset_disposal
  for each row execute function app.tg_gl_post();

create or replace function public.post_ledger_backfill()
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tenant uuid := app.auth_tenant_id();
  v_before int;
  v_after  int;
  r record;
begin
  perform app.fn_assert_accountant();
  select count(*) into v_before from public.journal_entry where tenant_id = v_tenant and source_kind is not null;
  for r in select id from public.fee_payment where tenant_id = v_tenant order by value_date, received_at loop
    perform app.fn_gl_post_fee_payment(r.id);
  end loop;
  for r in select id from public.expense_voucher where tenant_id = v_tenant and status = 'paid' order by paid_at loop
    perform app.fn_gl_post_expense_voucher(r.id);
  end loop;
  for r in select id from public.payroll_run where tenant_id = v_tenant and status in ('locked', 'paid') order by period_month loop
    perform app.fn_gl_post_payroll(r.id);
  end loop;
  for r in select id from public.inv_sale where tenant_id = v_tenant order by sold_at loop
    perform app.fn_gl_post_inv_sale(r.id);
  end loop;
  for r in select id from public.petty_cash_txn where tenant_id = v_tenant order by created_at loop
    perform app.fn_gl_post_petty_cash(r.id);
  end loop;
  for r in select id from public.staff_loan where tenant_id = v_tenant order by disbursed_at, created_at loop
    perform app.fn_gl_post_staff_loan(r.id);
  end loop;
  for r in select x.id from public.staff_loan_recovery x join public.staff_loan l on l.id = x.loan_id
            where l.tenant_id = v_tenant and x.payroll_run_id is null order by x.recovered_at loop
    perform app.fn_gl_post_staff_loan_recovery(r.id);
  end loop;
  for r in select id from public.asset where tenant_id = v_tenant order by purchased_on, created_at loop
    perform app.fn_gl_post_asset_purchase(r.id);
  end loop;
  for r in select id from public.asset_maintenance where tenant_id = v_tenant and is_capitalised order by reported_on, created_at loop
    perform app.fn_gl_post_asset_improvement(r.id);
  end loop;
  for r in select id from public.asset_depreciation_entry where tenant_id = v_tenant order by period, posted_at loop
    perform app.fn_gl_post_asset_depreciation(r.id);
  end loop;
  for r in select id from public.asset_disposal where tenant_id = v_tenant order by disposed_on loop
    perform app.fn_gl_post_asset_disposal(r.id);
  end loop;
  select count(*) into v_after from public.journal_entry where tenant_id = v_tenant and source_kind is not null;
  return v_after - v_before;
end;
$$;
