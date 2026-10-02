import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { formatPct } from '@/lib/format-money';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { ExportCollectionButton } from './export-button';

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK')}`;
const efficiency = (billed: number, collected: number) => (billed > 0 ? Math.round((1000 * collected) / billed) / 10 : null);
type SearchParams = { campus?: string; month?: string; class?: string };

function currentMonth(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' }).slice(0, 7);
}

export default async function CollectionDashboardPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();

  const { data: due } = await supabase.rpc('fee_collection_refresh_due');
  if (due) await supabaseServiceRole().rpc('refresh_fee_collection_metrics');

  const month = /^\d{4}-\d{2}$/.test(sp.month ?? '') ? (sp.month as string) : currentMonth();
  const monthStart = `${month}-01`;
  const next = new Date(Date.UTC(Number(month.slice(0, 4)), Number(month.slice(5, 7)), 1)).toISOString().slice(0, 10);
  const campusId = sp.campus || undefined;

  let monthQuery = supabase
    .from('v_fee_collection_monthly')
    .select('campus_id, class_id, billed_paisa, collected_paisa, outstanding_paisa, challan_count, refreshed_at')
    .gte('billing_period', monthStart)
    .lt('billing_period', next);
  if (campusId) monthQuery = monthQuery.eq('campus_id', campusId);

  const [monthRes, trendRes, campusRes, classRes] = await Promise.all([
    monthQuery,
    supabase.rpc('fn_fee_collection_trend', { p_campus_id: campusId, p_months: 12 }),
    supabase.from('campus').select('id, name').order('name'),
    supabase.from('class_level').select('id, name_en').order('ordinal'),
  ]);
  const rows = monthRes.data ?? [];
  const trend = trendRes.data ?? [];
  const campuses = campusRes.data ?? [];
  const classNames = new Map((classRes.data ?? []).map((c) => [c.id, c.name_en]));
  const campusNames = new Map(campuses.map((c) => [c.id, c.name]));

  const sum = (list: typeof rows, key: 'billed_paisa' | 'collected_paisa' | 'outstanding_paisa') => list.reduce((s, r) => s + Number(r[key]), 0);
  const billed = sum(rows, 'billed_paisa');
  const collected = sum(rows, 'collected_paisa');
  const byCampus = [...new Set(rows.map((r) => r.campus_id).filter((v): v is string => v !== null))].map((id) => {
    const own = rows.filter((r) => r.campus_id === id);
    return { id, billed: sum(own, 'billed_paisa'), collected: sum(own, 'collected_paisa') };
  });
  const byClass = [...new Set(rows.map((r) => r.class_id).filter((v): v is string => v !== null))].map((id) => {
    const own = rows.filter((r) => r.class_id === id);
    return { id, billed: sum(own, 'billed_paisa'), collected: sum(own, 'collected_paisa') };
  });
  const asOf = rows[0]?.refreshed_at ?? null;
  const maxBilled = Math.max(1, ...trend.map((t) => Number(t.billed_paisa)));

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Billing versus collection</h1>
          <p className="text-sm text-muted-foreground" data-testid="collection-as-of">
            FR-K30 — each month is measured against what that month billed; arrears paid later fill the older month. {asOf ? `As of ${new Date(asOf).toLocaleString()}; rebuilt at least hourly.` : 'Rebuilt at least hourly.'}
          </p>
        </div>
        <ExportCollectionButton />
      </div>

      <form className="flex flex-wrap items-end gap-3 text-sm" method="get">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Month</span>
          <input type="month" name="month" defaultValue={month} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Campus</span>
          <select name="campus" defaultValue={campusId ?? ''} className="h-9 rounded-md border bg-background px-2">
            <option value="">All campuses</option>
            {campuses.map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>

      <div className="grid gap-4 sm:grid-cols-4" data-testid="collection-kpis">
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground">Billed</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{pkr(billed)}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground">Collected</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold">{pkr(collected)}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground">Outstanding</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold" data-testid="kpi-outstanding">{pkr(billed - collected)}</CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-sm text-muted-foreground">Collection efficiency</CardTitle>
          </CardHeader>
          <CardContent className="text-xl font-semibold" data-testid="kpi-efficiency">{formatPct(efficiency(billed, collected))}</CardContent>
        </Card>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">12-month trend</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="collection-trend">
          {trend.map((t) => (
            <div key={t.billing_period} className="grid grid-cols-[5rem_1fr_9rem] items-center gap-3" data-testid="trend-point">
              <span className="text-muted-foreground">{t.billing_period.slice(0, 7)}</span>
              <div className="h-3 w-full rounded bg-muted">
                <div className="h-3 rounded bg-primary/30" style={{ width: `${(Number(t.billed_paisa) / maxBilled) * 100}%` }}>
                  <div className="h-3 rounded bg-primary" style={{ width: `${Number(t.billed_paisa) > 0 ? (Number(t.collected_paisa) / Number(t.billed_paisa)) * 100 : 0}%` }} />
                </div>
              </div>
              <span className="text-right">{pkr(Number(t.billed_paisa))} · {formatPct(t.collection_efficiency_pct === null ? null : Number(t.collection_efficiency_pct))}</span>
            </div>
          ))}
        </CardContent>
      </Card>

      {rows.length === 0 ? (
        <EmptyState title="No challans for this month" description="Nothing was billed in the selected month and scope." />
      ) : (
        <>
          {!campusId && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">By campus</CardTitle>
              </CardHeader>
              <CardContent className="space-y-1 text-sm" data-testid="by-campus">
                {byCampus.map((c) => (
                  <div key={c.id} className="flex justify-between border-b py-1">
                    <span>{campusNames.get(c.id) ?? 'Campus'}</span>
                    <span>
                      {pkr(c.billed)} billed · {pkr(c.collected)} collected · {formatPct(efficiency(c.billed, c.collected))}
                    </span>
                  </div>
                ))}
                <div className="flex justify-between pt-1 font-medium">
                  <span>All campuses</span>
                  <span>
                    {pkr(billed)} billed · {pkr(collected)} collected · {formatPct(efficiency(billed, collected))}
                  </span>
                </div>
              </CardContent>
            </Card>
          )}
          <Card>
            <CardHeader>
              <CardTitle className="text-base">By class</CardTitle>
            </CardHeader>
            <CardContent className="space-y-1 text-sm" data-testid="by-class">
              {byClass.map((c) => (
                <div key={c.id} className="flex justify-between border-b py-1">
                  <span>{classNames.get(c.id) ?? 'Class'}</span>
                  <span>
                    {pkr(c.billed)} billed · {pkr(c.collected)} collected · {pkr(c.billed - c.collected)} outstanding · {formatPct(efficiency(c.billed, c.collected))}
                  </span>
                </div>
              ))}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
