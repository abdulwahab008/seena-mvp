import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CensusForm } from './census-form';

// FR-T13: the annual census / EMIS return, reconstructed from enrolment dates as of the census
// date. Counting today's roll instead is what makes a return disagree with what the school reported.
export default async function CensusPage() {
  const supabase = await supabaseServer();
  const [{ data: campuses }, { data: specs }, { data: runs }] = await Promise.all([
    supabase.from('campus').select('id, name').eq('status', 'active').order('name'),
    supabase.from('census_framework_spec').select('framework, display_name, output_format').order('display_name'),
    supabase.from('census_return_run').select('id, campus_id, framework, census_date, status, total_students, unknown_age_count, incomplete, reconciliation_ok, file_path, file_sha256, generated_at').order('generated_at', { ascending: false }).limit(30),
  ]);
  const campusName = new Map((campuses ?? []).map((c) => [c.id, c.name]));
  const specName = new Map((specs ?? []).map((s) => [s.framework, s.display_name]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Census & EMIS returns</h1>
        <p className="text-sm text-muted-foreground">
          FR-T13 — enrolment counted as it stood on the census date: a student who left afterwards is still counted, one admitted afterwards is not. Class-by-gender and class-by-age tables must add up to the roll or the return is refused.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Generate a return</CardTitle>
        </CardHeader>
        <CardContent>
          <CensusForm campuses={(campuses ?? []).map((c) => ({ value: c.id, label: c.name }))} frameworks={(specs ?? []).map((s) => ({ value: s.framework, label: `${s.display_name} (${s.output_format.toUpperCase()})` }))} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Returns</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="census-runs">
          {(runs ?? []).length === 0 && <p className="text-muted-foreground">No returns generated yet.</p>}
          {(runs ?? []).map((r) => (
            <div key={r.id} className="space-y-1 border-b pb-3" data-testid="census-run">
              <div className="flex flex-wrap items-center justify-between gap-2">
                <span className="font-medium">
                  {specName.get(r.framework) ?? r.framework} · {campusName.get(r.campus_id) ?? ''} · as of {r.census_date}
                </span>
                <span className="flex items-center gap-2">
                  <Badge variant={r.status === 'done' ? 'success' : 'destructive'}>{r.status}</Badge>
                  {r.incomplete && <Badge variant="warning">incomplete</Badge>}
                  {r.file_path && (
                    <a className="underline-offset-2 hover:underline" href={`/api/census-returns/${r.id}/download`} data-testid="census-download">
                      Download
                    </a>
                  )}
                </span>
              </div>
              <p className="text-xs text-muted-foreground">
                {r.total_students?.toLocaleString('en-PK')} students on the roll · reconciliation {r.reconciliation_ok ? 'passed' : 'FAILED'}
                {r.incomplete ? ` · ${r.unknown_age_count} with unknown age` : ''}
                {r.file_sha256 ? ` · SHA-256 ${r.file_sha256.slice(0, 12)}…` : ''}
              </p>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
