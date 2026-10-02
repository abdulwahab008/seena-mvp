import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { BuilderForm, type DatasetOption } from './builder-form';
import { DeleteReportButton } from './report-actions';

// FR-S07: build a report from a published dataset, save it, share it. The column picker
// offers only what this role may see; the server assembles the SQL from its own whitelist.
export default async function ReportBuilderPage() {
  const supabase = await supabaseServer();
  const { data: user } = await supabase.auth.getUser();
  const { data: ds } = await supabase.rpc('fn_report_datasets');
  const datasets: DatasetOption[] = [];
  for (const d of ds ?? []) {
    const { data: cols } = await supabase.rpc('fn_report_columns', { p_dataset_key: d.dataset_key });
    datasets.push({ key: d.dataset_key, label: d.display_name, columns: (cols ?? []).map((c) => ({ key: c.key, label: c.label, type: c.type })) });
  }
  const { data: saved } = await supabase.from('saved_report').select('id, name, dataset_key, is_shared, owner_user_id, updated_at').order('updated_at', { ascending: false });

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Report builder</h1>
        <p className="text-sm text-muted-foreground">FR-S07 — pick a dataset, choose columns, filter and group, preview, and save. Shared reports run for each person with their own campus access.</p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">New report</CardTitle>
        </CardHeader>
        <CardContent>{datasets.length === 0 ? <p className="text-sm text-muted-foreground">No dataset is available to your role.</p> : <BuilderForm datasets={datasets} />}</CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Saved reports</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="saved-reports">
          {(saved ?? []).length === 0 && <p className="text-muted-foreground">Nothing saved yet.</p>}
          {(saved ?? []).map((r) => (
            <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b py-2" data-testid="saved-report">
              <Link href={`/reports/builder/${r.id}`} className="font-medium underline-offset-2 hover:underline">
                {r.name}
              </Link>
              <span className="flex items-center gap-2">
                <Badge variant="outline">{datasets.find((d) => d.key === r.dataset_key)?.label ?? r.dataset_key}</Badge>
                {r.is_shared && <Badge variant="outline">shared</Badge>}
                {r.owner_user_id === user.user?.id ? <DeleteReportButton id={r.id} /> : <span className="text-xs text-muted-foreground">shared with you</span>}
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
