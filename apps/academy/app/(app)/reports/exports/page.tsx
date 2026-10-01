import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AutoRefresh, ExportForm, type DatasetOption } from './export-form';

const KEYS = new Set(['students', 'fee_collection']);

export default async function ExportsPage() {
  const supabase = await supabaseServer();
  const { data: user } = await supabase.auth.getUser();
  const [datasetsRes, jobsRes, notesRes] = await Promise.all([
    supabase.from('report_dataset').select('dataset_key, display_name').order('display_name'),
    supabase.from('v_report_export_job').select('id, requested_by, dataset_key, status, row_count, error, created_at, finished_at, expires_at, downloadable').order('created_at', { ascending: false }).limit(30),
    supabase.from('user_notification').select('id, title, body, link, created_at, read_at').order('created_at', { ascending: false }).limit(5),
  ]);

  const when = (v: string | null) => (v ? new Date(v).toLocaleString() : '');
  const datasets: DatasetOption[] = (datasetsRes.data ?? []).filter((d) => KEYS.has(d.dataset_key)).map((d) => ({ key: d.dataset_key as DatasetOption['key'], label: d.display_name }));
  const jobs = (jobsRes.data ?? []).filter((j) => j.requested_by === user.user?.id);
  const pending = jobs.some((j) => j.status === 'queued' || j.status === 'running');

  return (
    <div className="space-y-6">
      <AutoRefresh active={pending} />
      <div>
        <h1 className="text-2xl font-semibold">Excel exports</h1>
        <p className="text-sm text-muted-foreground">FR-S08 — large exports are built in the background. Request one, carry on working, and download it here when it is ready (kept for 30 days).</p>
      </div>

      {(notesRes.data ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Recent notifications</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm" data-testid="notifications">
            {(notesRes.data ?? []).map((n) => (
              <p key={n.id}>
                <strong>{n.title}</strong> — {n.body} <span className="text-muted-foreground">{new Date(n.created_at).toLocaleString()}</span>
              </p>
            ))}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">New export</CardTitle>
        </CardHeader>
        <CardContent>
          <ExportForm datasets={datasets} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Your exports</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="export-jobs">
          {jobs.length === 0 && <p className="text-muted-foreground">No exports yet.</p>}
          {jobs.map((j) => (
            <div key={j.id ?? j.created_at} className="flex items-center justify-between gap-2 border-b py-2" data-testid="export-job">
              <span>
                {j.dataset_key} · {when(j.created_at)}
                {j.row_count !== null ? ` · ${j.row_count} rows` : ''}
              </span>
              <span className="flex items-center gap-3">
                <Badge variant={j.status === 'done' ? 'success' : j.status === 'failed' ? 'destructive' : 'outline'}>{j.status ?? ''}</Badge>
                {j.downloadable && (
                  <a className="underline-offset-2 hover:underline" href={`/api/reports/exports/${j.id}/download`} data-testid="export-download">
                    Download
                  </a>
                )}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
