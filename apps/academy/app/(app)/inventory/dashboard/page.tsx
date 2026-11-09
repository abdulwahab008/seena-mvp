import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { formatPkrCompact } from '@/lib/format-money';
import { todayPk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Breakdown, KpiGrid } from '@/components/module-dashboard';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'accountant'];

export default async function ShopDashboardPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const today = todayPk();
  const monthStart = `${today.slice(0, 8)}01`;

  const [{ data: todaySales }, { data: monthSales }, lowStock, { data: lowItems }, { data: onHand }, { data: items }] = await Promise.all([
    supabase.rpc('inventory_profit', { p_from: today, p_to: today }),
    supabase.rpc('inventory_profit', { p_from: monthStart, p_to: today }),
    supabase.from('v_stock_on_hand').select('item_id', { count: 'exact', head: true }).eq('at_or_below_reorder', true),
    supabase.from('v_stock_on_hand').select('store_id, item_id, item_name, size, on_hand, reorder_level').eq('at_or_below_reorder', true).order('on_hand').limit(8),
    supabase.from('v_stock_on_hand').select('item_id, on_hand'),
    supabase.from('inv_item').select('id, sale_price'),
  ]);

  const revenue = (rows: { revenue_paisa: number }[] | null) => (rows ?? []).reduce((sum, r) => sum + r.revenue_paisa, 0);
  const price = new Map((items ?? []).map((i) => [i.id, i.sale_price]));
  const stockValue = (onHand ?? []).reduce((sum, r) => sum + Math.max(0, r.on_hand ?? 0) * (price.get(r.item_id ?? '') ?? 0), 0);
  const monthProfit = (monthSales ?? []).reduce((sum, r) => sum + r.profit_paisa, 0);
  const topSellers = (monthSales ?? [])
    .filter((r) => r.revenue_paisa > 0)
    .slice(0, 8)
    .map((r) => ({ key: r.item_id, label: r.name, value: r.revenue_paisa, display: formatPkrCompact(r.revenue_paisa) }));
  const lowRows = (lowItems ?? []).map((r) => ({
    key: `${r.store_id}:${r.item_id}`,
    label: `${r.item_name ?? 'Item'}${r.size ? ` (${r.size})` : ''}`,
    value: r.on_hand ?? 0,
    display: `${r.on_hand ?? 0} left · reorder at ${r.reorder_level ?? 0}`,
  }));

  return (
    <>
      <PageHeader title="Shop dashboard" description="Counter sales today and this month, stock running low and the value of stock on hand." />
      <KpiGrid
        prefix="shop"
        kpis={[
          { id: 'today', label: "Today's sales", value: formatPkrCompact(revenue(todaySales)) },
          { id: 'month', label: 'Sales this month', value: formatPkrCompact(revenue(monthSales)) },
          { id: 'profit', label: 'Profit this month', value: formatPkrCompact(monthProfit) },
          { id: 'low-stock', label: 'Items at or below reorder level', value: lowStock.count ?? 0 },
          { id: 'stock-value', label: 'Stock value at sale price', value: formatPkrCompact(stockValue) },
        ]}
      />
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Breakdown title="Best sellers this month" rows={topSellers} empty="No sales this month." bars />
        <Breakdown title="Running low" rows={lowRows} empty="Nothing is at or below its reorder level." />
      </div>
    </>
  );
}
