import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AckControl, RefreshButton } from './variance-controls';

type SearchParams = { status?: string };
const LABEL: Record<string, string> = { behind: 'Behind', on_track: 'On track', no_plan: 'No plan' };

export default async function SyllabusVariancePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const status = sp.status && sp.status in LABEL ? sp.status : '';
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;

  // Worst first: behind pairs by largest shortfall, then the rest.
  let query = supabase
    .from('v_syllabus_variance')
    .select('section_id, subject_id, class_name, section_name, subject_name, expected_pct, actual_pct, variance_pct, classification, computed_at, ack_reason');
  if (campusId) query = query.eq('campus_id', campusId);
  if (status) query = query.eq('classification', status);
  const { data } = await query.order('variance_pct', { ascending: true, nullsFirst: false }).limit(1000);
  const rows = data ?? [];

  const { data: all } = campusId ? await supabase.from('v_syllabus_variance').select('classification, ack_reason').eq('campus_id', campusId).limit(5000) : { data: [] };
  const count = (c: string) => (all ?? []).filter((r) => r.classification === c).length;
  const unacknowledged = (all ?? []).filter((r) => r.classification === 'behind' && !r.ack_reason).length;
  const computedAt = rows[0]?.computed_at ? new Date(rows[0].computed_at).toLocaleString('en-GB', { timeZone: 'Asia/Karachi' }) : null;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Syllabus variance</h1>
        <p className="text-sm text-muted-foreground">
          FR-H12 — which class-subjects are behind their annual plan. Expected coverage counts every chapter whose target month has begun; behind means more than 5 points short. Rebuilt every day at 05:00.
        </p>
      </div>

      <div className="flex flex-wrap items-center gap-4 text-sm">
        <span data-testid="count-behind">
          <Badge variant="destructive">{count('behind')}</Badge> behind ({unacknowledged} unacknowledged)
        </span>
        <span>
          <Badge variant="success">{count('on_track')}</Badge> on track
        </span>
        <span>
          <Badge variant="outline">{count('no_plan')}</Badge> no plan
        </span>
        {campusId && <RefreshButton campusId={campusId} />}
        {computedAt && <span className="text-xs text-muted-foreground">Computed {computedAt}</span>}
      </div>

      <form method="get" className="flex items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Show</span>
          <select name="status" defaultValue={status} className="h-9 rounded-md border bg-background px-2">
            <option value="">All</option>
            <option value="behind">Behind</option>
            <option value="on_track">On track</option>
            <option value="no_plan">No plan</option>
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Filter
        </button>
      </form>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Class-subject grid ({rows.length})</CardTitle>
        </CardHeader>
        <CardContent className="overflow-x-auto">
          <table className="w-full text-left text-sm" data-testid="variance-grid">
            <thead>
              <tr className="border-b text-muted-foreground">
                <th className="py-1">Class</th>
                <th>Subject</th>
                <th>Expected</th>
                <th>Actual</th>
                <th>Variance</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {rows.length === 0 && (
                <tr>
                  <td colSpan={7} className="py-2 text-muted-foreground">
                    No syllabus pairs yet. Define a syllabus, then refresh.
                  </td>
                </tr>
              )}
              {rows.map((r) => (
                <tr key={`${r.section_id}-${r.subject_id}`} className="border-b" data-testid="variance-row">
                  <td className="py-2">
                    {r.class_name} {r.section_name}
                  </td>
                  <td>{r.subject_name}</td>
                  <td>{r.expected_pct === null ? '—' : `${r.expected_pct}%`}</td>
                  <td>{r.actual_pct}%</td>
                  <td>{r.variance_pct === null ? '—' : r.variance_pct}</td>
                  <td>
                    <Badge variant={r.classification === 'behind' ? 'destructive' : r.classification === 'on_track' ? 'success' : 'outline'}>{LABEL[r.classification ?? ''] ?? r.classification}</Badge>
                  </td>
                  <td>{r.classification === 'behind' && <AckControl sectionId={r.section_id!} subjectId={r.subject_id!} reason={r.ack_reason} />}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </CardContent>
      </Card>
    </div>
  );
}
