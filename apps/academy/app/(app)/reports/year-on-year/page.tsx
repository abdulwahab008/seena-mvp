import { supabaseServer } from '@/lib/supabase/server';
import { yoyQuerySchema } from '@/lib/validation';
import { formatInt, formatPaisa } from '@/lib/reports/pdf-layout';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';

// FR-S10: this session against a previous one, aligned on month-of-session (index 1 is
// the month the session starts), with "no data" kept distinct from zero.

const METRICS = [
  { key: 'fees_collected', label: 'Fees collected', unit: 'paisa' },
  { key: 'enrolment', label: 'Enrolment', unit: 'count' },
  { key: 'outstanding', label: 'Outstanding fees', unit: 'paisa' },
  { key: 'collection_rate', label: 'Collection rate', unit: 'percent' },
  { key: 'attendance_rate', label: 'Attendance rate', unit: 'percent' },
  { key: 'staff_cost_ratio', label: 'Staff cost ratio', unit: 'percent' },
] as const;

function fmt(unit: string, v: number | null): string {
  if (v === null) return 'no data';
  if (unit === 'paisa') return formatPaisa(v);
  if (unit === 'count') return formatInt(v);
  return `${v.toFixed(1)}%`;
}
const signed = (n: number, text: string) => (n > 0 ? `+${text}` : text);

export default async function YearOnYearPage({ searchParams }: { searchParams: Promise<Record<string, string | undefined>> }) {
  const q = yoyQuerySchema.parse(await searchParams);
  const supabase = await supabaseServer();
  const [{ data: sessions }, { data: campuses }] = await Promise.all([
    supabase.from('academic_session').select('id, tenant_id, name, starts_on, ends_on, campus_id').order('starts_on', { ascending: false }),
    supabase.from('campus').select('id, name').eq('status', 'active').order('name'),
  ]);
  const all = sessions ?? [];
  const tenantId = all[0]?.tenant_id;
  const current = all.find((s) => s.id === q.current) ?? all[0];
  const prior = all.find((s) => s.id === q.prior) ?? all.find((s) => current && s.starts_on < current.starts_on && s.id !== current.id);
  const campusIds = q.campus ? [q.campus] : (campuses ?? []).map((c) => c.id);
  const metric = METRICS.find((m) => m.key === q.metric) ?? METRICS[0];

  let rows: { month_index: number | null; current_label: string | null; prior_label: string | null; current_value: number | null; prior_value: number | null; abs_change: number | null; pct_change: number | null; status: string | null }[] = [];
  let overall: { months_compared: number | null; months_excluded: number | null; current_value: number | null; prior_value: number | null; abs_change: number | null; pct_change: number | null } | null = null;
  let classes: { class_code: string | null; group_code: string | null; display_name: string | null; session_id: string | null; enrolled: number | null }[] = [];
  if (tenantId && current && prior && campusIds.length > 0) {
    const args = { tenant_id: tenantId, campus_ids: campusIds, metric_key: metric.key, current_session_id: current.id, prior_session_id: prior.id };
    const [cmp, ovr, cls] = await Promise.all([
      supabase.rpc('fn_yoy_compare', args),
      supabase.rpc('fn_yoy_overall', args).maybeSingle(),
      supabase.rpc('fn_yoy_class_enrolment', { tenant_id: tenantId, campus_ids: campusIds, session_ids: [current.id, prior.id] }),
    ]);
    rows = cmp.data ?? [];
    overall = ovr.data;
    classes = cls.data ?? [];
  }

  const classKeys = [...new Map(classes.map((c) => [`${c.class_code}|${c.group_code}`, c.display_name ?? c.class_code])).entries()];

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Year-on-year comparison</h1>
        <p className="text-sm text-muted-foreground">FR-S10 — months are aligned by position in the session (month 1 is the month the session starts), so April–March and August–July campuses compare like with like.</p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm" data-testid="yoy-filters">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Measure</span>
          <select name="metric" defaultValue={metric.key} className="h-9 rounded-md border bg-background px-2">
            {METRICS.map((m) => (
              <option key={m.key} value={m.key}>
                {m.label}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">This session</span>
          <select name="current" defaultValue={current?.id} className="h-9 rounded-md border bg-background px-2">
            {all.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Compared with</span>
          <select name="prior" defaultValue={prior?.id} className="h-9 rounded-md border bg-background px-2">
            {all.map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Campus</span>
          <select name="campus" defaultValue={q.campus ?? ''} className="h-9 rounded-md border bg-background px-2">
            <option value="">All my campuses</option>
            {(campuses ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Compare
        </button>
      </form>

      {!current || !prior ? (
        <EmptyState title="Two sessions are needed" description="Create or keep a previous academic session to compare against." />
      ) : (
        <>
          {overall && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">
                  {metric.label}: {current.name} vs {prior.name}
                </CardTitle>
              </CardHeader>
              <CardContent className="space-y-1 text-sm" data-testid="yoy-overall">
                {overall.months_compared ? (
                  <p>
                    Over the {overall.months_compared} months both sessions have data: {fmt(metric.unit, overall.current_value)} vs {fmt(metric.unit, overall.prior_value)}
                    {overall.abs_change !== null && <> · {signed(overall.abs_change, fmt(metric.unit, overall.abs_change))}</>}
                    {overall.pct_change !== null ? <> · {signed(overall.pct_change, `${overall.pct_change.toFixed(1)}%`)}</> : <> · no baseline for a percentage</>}
                  </p>
                ) : (
                  <p>No month has data in both sessions.</p>
                )}
                {!!overall.months_excluded && <p className="text-muted-foreground">{overall.months_excluded} months were left out of the change because one session has no data for them.</p>}
              </CardContent>
            </Card>
          )}

          <div className="overflow-x-auto rounded-md border" data-testid="yoy-table">
            <table className="w-full min-w-[720px] text-sm">
              <thead className="bg-muted/50 text-left">
                <tr>
                  <th className="p-2">Month of session</th>
                  <th className="p-2">{current.name}</th>
                  <th className="p-2">{prior.name}</th>
                  <th className="p-2">Change</th>
                  <th className="p-2">Change %</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => (
                  <tr key={r.month_index} className="border-t" data-testid="yoy-row" data-status={r.status}>
                    <td className="p-2">
                      <div className="font-medium">{r.month_index}</div>
                      <div className="text-xs text-muted-foreground">
                        {r.current_label ?? '—'} · {r.prior_label ?? '—'}
                      </div>
                    </td>
                    <td className="p-2">{fmt(metric.unit, r.current_value)}</td>
                    <td className="p-2">{fmt(metric.unit, r.prior_value)}</td>
                    <td className="p-2" data-testid="yoy-abs">
                      {r.abs_change === null ? '—' : signed(r.abs_change, fmt(metric.unit, r.abs_change))}
                    </td>
                    <td className="p-2" data-testid="yoy-pct">
                      {r.status === 'no_data' ? <Badge variant="outline">no data</Badge> : r.status === 'no_baseline' ? <Badge variant="outline">no baseline</Badge> : r.pct_change === null ? '—' : signed(r.pct_change, `${r.pct_change.toFixed(1)}%`)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Enrolment by class and group</CardTitle>
            </CardHeader>
            <CardContent className="overflow-x-auto text-sm" data-testid="yoy-classes">
              <p className="mb-2 text-muted-foreground">Matched on the stable class and group codes, so a renamed class stays one row.</p>
              <table className="w-full min-w-[480px]">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="p-2">Class</th>
                    <th className="p-2">{current.name}</th>
                    <th className="p-2">{prior.name}</th>
                    <th className="p-2">Change</th>
                  </tr>
                </thead>
                <tbody>
                  {classKeys.map(([key, name]) => {
                    const cur = classes.find((c) => `${c.class_code}|${c.group_code}` === key && c.session_id === current.id)?.enrolled ?? null;
                    const pri = classes.find((c) => `${c.class_code}|${c.group_code}` === key && c.session_id === prior.id)?.enrolled ?? null;
                    const pct = cur !== null && pri !== null && pri !== 0 ? Math.round(((cur - pri) * 1000) / pri) / 10 : null;
                    return (
                      <tr key={key} className="border-t" data-testid="yoy-class-row">
                        <td className="p-2">{name}</td>
                        <td className="p-2">{cur ?? 'no data'}</td>
                        <td className="p-2">{pri ?? 'no data'}</td>
                        <td className="p-2">{cur !== null && pri !== null ? `${signed(cur - pri, String(cur - pri))}${pct !== null ? ` (${signed(pct, pct.toFixed(1))}%)` : ''}` : '—'}</td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
