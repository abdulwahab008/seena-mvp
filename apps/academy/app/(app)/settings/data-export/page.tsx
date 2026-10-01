import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { RequestExportButton } from './request-button';

// FR-A19: a complete copy of the school's records in open formats (UTF-8 CSV with a byte-order
// mark so Excel shows Urdu correctly, plus a manifest of row counts). Owner only.
export default async function DataExportPage() {
  const supabase = await supabaseServer();
  const { data: permissions } = await supabase.rpc('my_effective_permissions');
  const allowed = (permissions ?? []).includes('tenant.export');

  const { data: requests } = allowed
    ? await supabase.from('data_export_request').select('id, status, bytes, checksum_sha256, row_counts, expires_at, created_at, completed_at, error').order('created_at', { ascending: false }).limit(20)
    : { data: [] };
  const busy = (requests ?? []).some((r) => r.status === 'queued' || r.status === 'running');
  const now = Date.now();

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Export school data</h1>
        <p className="text-sm text-muted-foreground">
          FR-A19 — students, guardians, enrolments, attendance, fee challans, payments, marks and staff, each as its own CSV, with a manifest.json of row counts. Your records are yours: no lock-in.
        </p>
      </div>

      {!allowed ? (
        <div role="alert" className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" data-testid="export-not-permitted">
          Only the school owner can export all school data.
        </div>
      ) : (
        <>
          <Card>
            <CardContent className="space-y-3 pt-6 text-sm">
              <RequestExportButton busy={busy} />
              <p className="text-muted-foreground">The archive is private and its download link works for 72 hours; after that you can simply request a new one.</p>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Your exports</CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm" data-testid="tenant-exports">
              {(requests ?? []).length === 0 && <p className="text-muted-foreground">No exports yet.</p>}
              {(requests ?? []).map((r) => {
                const live = r.status === 'done' && r.expires_at !== null && new Date(r.expires_at).getTime() > now;
                const total = r.row_counts ? Object.values(r.row_counts as Record<string, number>).reduce((s, n) => s + Number(n), 0) : null;
                return (
                  <div key={r.id} className="space-y-1 border-b pb-3" data-testid="tenant-export">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span>{new Date(r.created_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}</span>
                      <span className="flex items-center gap-3">
                        <Badge variant={r.status === 'done' && live ? 'success' : r.status === 'failed' ? 'destructive' : 'outline'}>{r.status === 'done' && !live ? 'expired' : r.status}</Badge>
                        {live && (
                          <a className="underline-offset-2 hover:underline" href={`/api/tenant-exports/${r.id}/download`} data-testid="tenant-export-download">
                            Download
                          </a>
                        )}
                      </span>
                    </div>
                    {r.status === 'done' && (
                      <p className="text-xs text-muted-foreground">
                        {total?.toLocaleString('en-PK')} rows · {r.bytes ? `${(Number(r.bytes) / 1024).toFixed(0)} KB` : ''} · SHA-256 {r.checksum_sha256?.slice(0, 16)}…
                        {live ? ` · link valid until ${new Date(r.expires_at!).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}` : ' · the link has expired — request a new export'}
                      </p>
                    )}
                    {r.status === 'failed' && r.error && <p className="text-xs text-destructive">{r.error}</p>}
                  </div>
                );
              })}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
