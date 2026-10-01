import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';

type SearchParams = { user?: string; from?: string; to?: string };

export default async function ReportAuditPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();

  let q = supabase.from('report_audit').select('id, user_id, report_key, dataset_key, row_count, contains_pii, reason, destination, executed_at').order('executed_at', { ascending: false }).limit(200);
  if (sp.user) q = q.eq('user_id', sp.user);
  if (sp.from) q = q.gte('executed_at', `${sp.from}T00:00:00+05:00`);
  if (sp.to) q = q.lte('executed_at', `${sp.to}T23:59:59.999+05:00`);
  const [{ data: rows, error }, { data: alerts }] = await Promise.all([
    q,
    supabase.from('report_audit_alert').select('id, user_id, report_keys, pii_report_count, created_at').order('created_at', { ascending: false }).limit(20),
  ]);

  const exportHref = `/api/reports/audit/export?${new URLSearchParams(Object.entries(sp).filter(([, v]) => Boolean(v)) as [string, string][]).toString()}`;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Report and export audit</h1>
        <p className="text-sm text-muted-foreground">FR-S11 — who ran or exported what, append-only. Exporting this list is itself recorded.</p>
      </div>

      {(alerts ?? []).length > 0 && (
        <Card className="border-amber-300">
          <CardHeader>
            <CardTitle className="text-base">Alerts: more than 3 personal-data exports in 24 hours</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm" data-testid="pii-alerts">
            {(alerts ?? []).map((a) => (
              <p key={a.id}>
                User {a.user_id} exported {a.pii_report_count} reports ({a.report_keys.join(', ')}) — {new Date(a.created_at).toLocaleString()}
              </p>
            ))}
          </CardContent>
        </Card>
      )}

      <form className="flex flex-wrap items-end gap-3 text-sm" method="get">
        <label className="space-y-1">
          <span>User id</span>
          <input name="user" defaultValue={sp.user} className="h-9 w-72 rounded-md border bg-background px-2" />
        </label>
        <label className="space-y-1">
          <span>From</span>
          <input name="from" type="date" defaultValue={sp.from} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <label className="space-y-1">
          <span>To</span>
          <input name="to" type="date" defaultValue={sp.to} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3 hover:bg-accent">
          Filter
        </button>
        <a href={exportHref} className="inline-flex h-9 items-center rounded-md border px-3 hover:bg-accent" data-testid="export-audit">
          Export this list (CSV)
        </a>
      </form>

      {error ? (
        <p role="alert" className="text-sm text-destructive">
          You do not have access to the audit trail.
        </p>
      ) : (rows ?? []).length === 0 ? (
        <EmptyState title="No report runs recorded" description="Runs and exports appear here as they happen." />
      ) : (
        <div className="overflow-x-auto rounded-md border" data-testid="audit-table">
          <table className="w-full min-w-[800px] text-sm">
            <thead className="bg-muted/50 text-left">
              <tr>
                <th className="p-2">When</th>
                <th className="p-2">User</th>
                <th className="p-2">Report</th>
                <th className="p-2">Rows</th>
                <th className="p-2">Destination</th>
                <th className="p-2">Personal data</th>
                <th className="p-2">Reason</th>
              </tr>
            </thead>
            <tbody>
              {(rows ?? []).map((r) => (
                <tr key={r.id} className="border-t" data-testid="audit-row">
                  <td className="p-2">{new Date(r.executed_at).toLocaleString()}</td>
                  <td className="p-2 font-mono text-xs">{r.user_id.slice(0, 8)}</td>
                  <td className="p-2">{r.report_key}</td>
                  <td className="p-2">{r.row_count}</td>
                  <td className="p-2">{r.destination}</td>
                  <td className="p-2">{r.contains_pii ? <Badge variant="warning">PII</Badge> : '—'}</td>
                  <td className="p-2">{r.reason ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
