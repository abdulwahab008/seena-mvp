import { supabaseServer } from '@/lib/supabase/server';
import { formatPct, formatPkrCompact } from '@/lib/format-money';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';

export default async function OwnerDashboardPage() {
  const supabase = await supabaseServer();
  const [kpiRes, defRes, freshRes] = await Promise.all([
    supabase.from('v_owner_kpi').select('*').order('campus_name'),
    supabase.from('metric_definition').select('metric_key, display_name, numerator_desc, denominator_desc, note'),
    supabase.rpc('agg_freshness').maybeSingle(),
  ]);
  const rows = kpiRes.data ?? [];
  const defs = defRes.data ?? [];
  const fresh = freshRes.data;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Owner dashboard</h1>
        <p className="text-sm text-muted-foreground">FR-S02 — this month to date, every campus you can see, from the nightly aggregates.</p>
      </div>

      {fresh?.is_stale && (
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" data-testid="stale-banner">
          This data is more than 26 hours old — the last nightly refresh did not complete.
          {fresh.last_failure_at ? ` Last failure: ${new Date(fresh.last_failure_at).toLocaleString()}.` : ''}
        </div>
      )}

      {rows.length === 0 ? (
        <EmptyState title="No campus data yet" description="Figures appear after the first nightly refresh, or if your account has no campuses assigned." />
      ) : (
        <div className="overflow-x-auto rounded-md border" data-testid="owner-kpi-table">
          <table className="w-full min-w-[960px] text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="p-2">Campus</th>
                <th className="p-2">Billed</th>
                <th className="p-2">Collected</th>
                <th className="p-2">Collection</th>
                <th className="p-2">Outstanding</th>
                <th className="p-2">0–30</th>
                <th className="p-2">31–60</th>
                <th className="p-2">60+</th>
                <th className="p-2">Staff cost ratio</th>
                <th className="p-2">Attendance</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.campus_id} className="border-t" data-testid="owner-kpi-row">
                  <td className="p-2 font-medium">{r.campus_name}</td>
                  <td className="p-2">{formatPkrCompact(Number(r.billed_paisa ?? 0))}</td>
                  <td className="p-2">{formatPkrCompact(Number(r.collected_paisa ?? 0))}</td>
                  <td className="p-2" data-testid="collection-pct">{formatPct(r.collection_pct === null ? null : Number(r.collection_pct))}</td>
                  <td className="p-2">{formatPkrCompact(Number(r.outstanding_paisa ?? 0))}</td>
                  <td className="p-2">{formatPkrCompact(Number(r.outstanding_0_30_paisa ?? 0))}</td>
                  <td className="p-2">{formatPkrCompact(Number(r.outstanding_31_60_paisa ?? 0))}</td>
                  <td className="p-2">{formatPkrCompact(Number(r.outstanding_60plus_paisa ?? 0))}</td>
                  <td className="p-2">
                    {r.staff_cost_ratio === null ? '—' : `${(Number(r.staff_cost_ratio) * 100).toFixed(1)}%`}{' '}
                    {!r.payroll_locked && r.payroll_status && r.payroll_status !== 'none' && <Badge variant="warning">payroll not locked</Badge>}
                  </td>
                  <td className="p-2">{formatPct(r.attendance_pct === null ? null : Number(r.attendance_pct))}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">How these are calculated</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="metric-definitions">
          {defs.map((d) => (
            <p key={d.metric_key}>
              <strong>{d.display_name}</strong> = {d.numerator_desc}
              {d.denominator_desc !== 'n/a' ? ` ÷ ${d.denominator_desc}` : ''}. {d.note}
            </p>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
