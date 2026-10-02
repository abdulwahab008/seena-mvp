import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { ExportDrilldownButton } from '../export-button';

// FR-S04: the rows behind a dashboard number. Reads the live drill-down views
// (security_invoker, so the base tables' RLS bounds what comes back).

const METRICS = {
  outstanding: { key: 'outstanding', title: 'Outstanding fees', blurb: 'Every challan with an unpaid balance, with the student it belongs to.' },
  absentees: { key: 'attendance_rate', title: 'Absentees', blurb: 'Students marked absent on the chosen day.' },
  staff_cost: { key: 'staff_cost_ratio', title: 'Staff cost', blurb: 'Payroll lines of the chosen month, one per employee.' },
} as const;
type MetricSlug = keyof typeof METRICS;
const BUCKETS = ['0_30', '31_60', '60_plus'] as const;
type Bucket = (typeof BUCKETS)[number];
const BUCKET_LABEL: Record<Bucket, string> = { '0_30': '0–30 days', '31_60': '31–60 days', '60_plus': '60+ days' };
const LIMIT = 5000;

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const todayIso = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

export default async function DrilldownPage({ params, searchParams }: { params: Promise<{ metric: string }>; searchParams: Promise<{ campus?: string; bucket?: string; day?: string }> }) {
  const { metric } = await params;
  if (!(metric in METRICS)) notFound();
  const slug = metric as MetricSlug;
  const def = METRICS[slug];
  const sp = await searchParams;
  const campusId = sp.campus && /^[0-9a-f-]{36}$/i.test(sp.campus) ? sp.campus : undefined;
  const bucket = BUCKETS.find((b) => b === sp.bucket);
  const day = /^\d{4}-\d{2}-\d{2}$/.test(sp.day ?? '') ? (sp.day as string) : todayIso();

  const supabase = await supabaseServer();
  const { data: permitted } = await supabase.rpc('fn_drilldown_permitted', { p_metric_key: def.key });

  const header = (
    <div>
      <Link href="/dashboard/owner" className="text-sm text-muted-foreground underline">
        Back to owner dashboard
      </Link>
      <h1 className="mt-1 text-2xl font-semibold">{def.title}</h1>
      <p className="text-sm text-muted-foreground">FR-S04 — {def.blurb}</p>
    </div>
  );

  if (!permitted) {
    return (
      <div className="space-y-6">
        {header}
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" data-testid="drilldown-not-permitted">
          Not permitted: your role can see this figure on the dashboard but not the individual records behind it. Ask the school owner if you need access.
        </div>
      </div>
    );
  }

  const reconcile = await supabase.rpc('fn_metric_reconcile', { metric_key: def.key, campus_id: (campusId ?? null) as string, on_day: day });
  const rec = reconcile.data?.[0];

  let rows: Record<string, string | number | null>[] = [];
  let columns: { key: string; label: string; money?: boolean }[] = [];
  let totalPaisa: number | null = null;
  if (slug === 'outstanding') {
    let q = supabase.from('v_drilldown_outstanding').select('challan_no, gr_number, student_name, class_name, section_name, campus_name, due_date, age_days, balance_paisa, bucket').order('balance_paisa', { ascending: false }).order('challan_no').range(0, LIMIT - 1);
    if (campusId) q = q.eq('campus_id', campusId);
    if (bucket) q = q.eq('bucket', bucket);
    rows = (await q).data ?? [];
    columns = [
      { key: 'challan_no', label: 'Challan' }, { key: 'gr_number', label: 'GR no' }, { key: 'student_name', label: 'Student' },
      { key: 'class_name', label: 'Class' }, { key: 'section_name', label: 'Section' }, { key: 'campus_name', label: 'Campus' },
      { key: 'due_date', label: 'Due' }, { key: 'age_days', label: 'Days overdue' }, { key: 'balance_paisa', label: 'Outstanding', money: true },
    ];
    totalPaisa = rows.reduce((s, r) => s + Number(r.balance_paisa ?? 0), 0);
  } else if (slug === 'absentees') {
    let q = supabase.from('v_drilldown_absentees').select('gr_number, student_name, class_name, section_name, campus_name, attendance_date').eq('attendance_date', day).order('class_name').order('section_name').order('gr_number').range(0, LIMIT - 1);
    if (campusId) q = q.eq('campus_id', campusId);
    rows = (await q).data ?? [];
    columns = [{ key: 'gr_number', label: 'GR no' }, { key: 'student_name', label: 'Student' }, { key: 'class_name', label: 'Class' }, { key: 'section_name', label: 'Section' }, { key: 'campus_name', label: 'Campus' }, { key: 'attendance_date', label: 'Date' }];
  } else {
    const monthStart = `${day.slice(0, 7)}-01`;
    let q = supabase.from('v_drilldown_staff_cost').select('employee_code, full_name, campus_name, period_month, run_status, gross_paisa, net_paisa').eq('period_month', monthStart).order('full_name').range(0, LIMIT - 1);
    if (campusId) q = q.eq('campus_id', campusId);
    rows = (await q).data ?? [];
    columns = [{ key: 'employee_code', label: 'Code' }, { key: 'full_name', label: 'Staff member' }, { key: 'campus_name', label: 'Campus' }, { key: 'run_status', label: 'Payroll' }, { key: 'gross_paisa', label: 'Gross', money: true }, { key: 'net_paisa', label: 'Net', money: true }];
    totalPaisa = rows.reduce((s, r) => s + Number(r.gross_paisa ?? 0), 0);
  }

  const base = `/dashboard/drilldown/${slug}`;
  const qs = (extra: Record<string, string | undefined>) => {
    const p = new URLSearchParams();
    const all = { campus: campusId, bucket, day: sp.day, ...extra };
    for (const [k, v] of Object.entries(all)) if (v) p.set(k, v);
    const s = p.toString();
    return s ? `${base}?${s}` : base;
  };

  return (
    <div className="space-y-6">
      {header}

      {rec?.exceeds_tolerance && (
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" data-testid="reconciliation-notice">
          The dashboard figure and these live rows differ by {Number(rec.delta_pct).toFixed(2)}%. Dashboard (aggregate): {slug === 'absentees' ? Number(rec.agg_value) : pkr(Number(rec.agg_value))}; live now:{' '}
          {slug === 'absentees' ? Number(rec.live_value) : pkr(Number(rec.live_value))}. The aggregate was last refreshed {rec.agg_refreshed_at ? new Date(rec.agg_refreshed_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' }) : 'never'} — a back-dated entry since then explains the gap.
        </div>
      )}

      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2 text-sm">
          {slug === 'outstanding' && (
            <>
              <Link href={qs({ bucket: undefined })}>
                <Badge variant={bucket ? 'outline' : 'default'}>All ages</Badge>
              </Link>
              {BUCKETS.map((b) => (
                <Link key={b} href={qs({ bucket: b })}>
                  <Badge variant={bucket === b ? 'default' : 'outline'}>{BUCKET_LABEL[b]}</Badge>
                </Link>
              ))}
            </>
          )}
          {slug !== 'outstanding' && (
            <form method="get" className="flex items-center gap-2">
              {campusId && <input type="hidden" name="campus" value={campusId} />}
              <label className="flex items-center gap-2">
                <span className="text-muted-foreground">{slug === 'absentees' ? 'Day' : 'Month containing'}</span>
                <input type="date" name="day" defaultValue={day} className="h-9 rounded-md border bg-background px-2" />
              </label>
              <button type="submit" className="h-9 rounded-md border px-3">
                Show
              </button>
            </form>
          )}
        </div>
        <ExportDrilldownButton filters={{ metric: slug, campusId, bucket, onDay: slug === 'outstanding' ? undefined : day }} />
      </div>

      {rows.length === 0 ? (
        <EmptyState title="No rows" description="Nothing matches these filters right now." />
      ) : (
        <Card>
          <CardHeader>
            <CardTitle className="text-base" data-testid="drilldown-summary">
              {rows.length.toLocaleString('en-PK')} {rows.length === 1 ? 'row' : 'rows'}
              {totalPaisa !== null && <> · total {pkr(totalPaisa)}</>}
              {rows.length >= LIMIT && <> · showing the first {LIMIT.toLocaleString('en-PK')}; export for the full list</>}
            </CardTitle>
          </CardHeader>
          <CardContent className="overflow-x-auto">
            <table className="w-full min-w-[720px] text-sm" data-testid="drilldown-table">
              <thead className="text-left text-muted-foreground">
                <tr>
                  {columns.map((c) => (
                    <th key={c.key} className="p-2">
                      {c.label}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {rows.map((r, i) => (
                  <tr key={i} className="border-t" data-testid="drilldown-row">
                    {columns.map((c) => (
                      <td key={c.key} className="p-2">
                        {c.money ? pkr(Number(r[c.key] ?? 0)) : (r[c.key] ?? '—')}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </CardContent>
        </Card>
      )}
    </div>
  );
}
