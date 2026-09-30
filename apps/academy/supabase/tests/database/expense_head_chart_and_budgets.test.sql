-- pgTAP tests for FR-L10: Expense head chart with budgets
-- Run with: npx supabase test db

begin;
select plan(18);

-- ─── Setup ────────────────────────────────────────────────────────────────────

select id as tenant_id from public.tenant limit 1 \gset
select id as campus_id from public.campus where tenant_id = :'tenant_id' limit 1 \gset
select gen_random_uuid() as admin_uid \gset
insert into auth.users (id, email, encrypted_password, email_confirmed_at, aud, role)
values (:'admin_uid', 'l10_owner@test.com', 'x', now(), 'authenticated', 'authenticated');
insert into public.app_user (user_id, tenant_id, app_role, full_name)
values (:'admin_uid', :'tenant_id', 'owner', 'L10 Owner');

do $$
declare
  v_tenant_id uuid;
begin
  select id into v_tenant_id from public.tenant limit 1;
  perform public.seed_default_expense_heads(v_tenant_id);
end;
$$;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'tenant_id', :'tenant_id',
    'app_role', 'owner',
    'campus_ids', json_build_array(:'campus_id'),
    'sub', :'admin_uid'
  )::text,
  true
);

-- ─── Test 1: expense_head has hierarchy columns ────────────────────────────

select has_column('public', 'expense_head', 'parent_id', 'expense_head has parent_id');
select has_column('public', 'expense_head', 'level',     'expense_head has level');
select has_column('public', 'expense_head', 'is_leaf',   'expense_head has is_leaf');

-- ─── Test 2: seeded heads are level=1, is_leaf=true, parent_id=null ───────

select is(
  (select count(*) from public.expense_head where parent_id is null and level = 1 and is_leaf = true),
  (select count(*) from public.expense_head),
  'All seeded heads are roots with is_leaf=true'
);

-- ─── Test 3: create root head ─────────────────────────────────────────────

select lives_ok(
  $$select public.create_expense_head('ADMIN', 'Administration', 'انتظامی', false)$$,
  'Can create a root expense head'
);

select is(
  (select level from public.expense_head where code = 'ADMIN'),
  1::smallint,
  'Root head has level=1'
);
select is(
  (select is_leaf from public.expense_head where code = 'ADMIN'),
  true,
  'Root head starts as is_leaf=true'
);

-- ─── Test 4: create child head inherits level and marks parent non-leaf ────

do $$
declare
  v_parent_id uuid;
  v_child_id  uuid;
begin
  select id into v_parent_id from public.expense_head where code = 'ADMIN';
  v_child_id := public.create_expense_head('ADMIN_SALARIES', 'Admin Salaries', 'تنخواہیں', false);
  -- manually set parent via RPC
  perform public.update_expense_head(
    v_child_id,
    null, null, null, null,
    v_parent_id,
    true  -- set_parent = true
  );
end;
$$;

select is(
  (select level from public.expense_head where code = 'ADMIN_SALARIES'),
  2::smallint,
  'Child head inherits level = parent.level + 1'
);
select is(
  (select is_leaf from public.expense_head where code = 'ADMIN'),
  false,
  'Parent marked is_leaf=false after child added'
);
select is(
  (select is_leaf from public.expense_head where code = 'ADMIN_SALARIES'),
  true,
  'Child head is is_leaf=true'
);

-- ─── Test 5: expense_head_campus table exists ─────────────────────────────

select has_table('public', 'expense_head_campus', 'expense_head_campus table exists');

-- ─── Test 6: expense_budget table exists with correct columns ─────────────

select has_table('public', 'expense_budget', 'expense_budget table exists');
select has_column('public', 'expense_budget', 'budget_month',  'expense_budget has budget_month');
select has_column('public', 'expense_budget', 'amount_paisa',  'expense_budget has amount_paisa');

-- ─── Test 7: set_expense_budget upserts correctly ─────────────────────────

do $$
declare
  v_head_id    uuid;
  v_campus_id  uuid;
  v_session_id uuid;
begin
  select id into v_head_id from public.expense_head where code = 'ADMIN_SALARIES';
  select id into v_campus_id from public.campus limit 1;
  select id into v_session_id from public.academic_session limit 1;

  perform public.set_expense_budget(
    v_head_id,
    v_campus_id,
    v_session_id,
    '2026-08-15',  -- will be normalised to 2026-08-01
    500000         -- 5,000 PKR
  );
end;
$$;

select is(
  (select amount_paisa from public.expense_budget where budget_month = '2026-08-01' limit 1),
  500000::bigint,
  'Budget upserted with normalised month'
);

-- ─── Test 8: v_expense_budget_vs_actual view exists ─────────────────────

select has_view('public', 'v_expense_budget_vs_actual', 'view v_expense_budget_vs_actual exists');

-- ─── Test 9: get_expense_chart RPC returns rows ──────────────────────────

select ok(
  (select count(*) from public.get_expense_chart(null, null, null)) > 0,
  'get_expense_chart() returns rows'
);

-- ─── Test 10: leaf guard prevents voucher on non-leaf head ───────────────
-- (Only testable if expense_voucher is accessible; mark as TODO if not seeded)
-- We just verify the trigger exists on expense_voucher
select has_trigger(
  'public',
  'expense_voucher',
  'trg_voucher_leaf_head_guard',
  'leaf guard trigger exists on expense_voucher'
);

select * from finish();
rollback;
