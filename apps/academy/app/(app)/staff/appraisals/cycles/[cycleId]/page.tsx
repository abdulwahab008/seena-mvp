import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CompetenciesForm, PublishButton } from '../../appraisal-forms';

export const dynamic = 'force-dynamic';

type Report = {
  eligible: number; scored: number; average_score: number | null; in_progress: number; released: number; awaiting_acknowledgement: number; final: number;
  excluded: { staff_id: string; name: string; employee_code: string; service_days: number }[]; excluded_count: number; min_service_days: number; closes_on: string;
};

export default async function AppraisalCyclePage({ params }: { params: Promise<{ cycleId: string }> }) {
  const { cycleId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(cycleId)) notFound();
  const actor = await getCurrentActor();
  if (!isHrWriter(actor?.role)) {
    return (
      <div className="space-y-2">
        <h1 className="text-2xl font-semibold">Appraisal cycle</h1>
        <p className="text-sm text-muted-foreground">Cycles are managed by HR and the Owner.</p>
      </div>
    );
  }
  const supabase = await supabaseServer();
  const { data: cycle } = await supabase.from('appraisal_cycle').select('id, name, opens_on, closes_on, min_service_days, status, published_at').eq('id', cycleId).maybeSingle();
  if (!cycle) notFound();
  const { data: competencies } = await supabase.from('appraisal_competency').select('id, name, weight_pct, sort_order').eq('cycle_id', cycleId).order('sort_order');
  const { data: appraisals } = await supabase
    .from('appraisal')
    .select('id, status, total_score, rater_id, staff:staff_id(full_name, employee_code)')
    .eq('cycle_id', cycleId)
    .order('created_at');
  const { data: reportRaw } = cycle.status === 'draft' ? { data: null } : await supabase.rpc('appraisal_cycle_report', { p_cycle_id: cycleId });
  const report = reportRaw as unknown as Report | null;
  const raterIds = [...new Set((appraisals ?? []).map((a) => a.rater_id))];
  const { data: raters } = raterIds.length ? await supabase.from('app_user').select('user_id, full_name').in('user_id', raterIds) : { data: [] as { user_id: string; full_name: string }[] };
  const raterName = new Map((raters ?? []).map((r) => [r.user_id, r.full_name]));
  const sum = (competencies ?? []).reduce((s, c) => s + Math.round(Number(c.weight_pct) * 100), 0) / 100;
  const text = (competencies ?? []).map((c) => `${c.name} | ${Number(c.weight_pct)}`).join('\n');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold" data-testid="cycle-name">
            {cycle.name}
          </h1>
          <p className="text-sm text-muted-foreground">
            {cycle.opens_on} to {cycle.closes_on} · staff need at least {cycle.min_service_days} days of service at {cycle.closes_on}
          </p>
          <p className="text-sm">
            <Link href="/staff/appraisals" className="underline">
              All cycles
            </Link>
          </p>
        </div>
        <Badge variant={cycle.status === 'draft' ? 'outline' : 'success'} data-testid="cycle-status">
          {cycle.status}
        </Badge>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Competencies and weights</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm">
          {cycle.status === 'draft' ? (
            <>
              <CompetenciesForm cycleId={cycleId} initialText={text} />
              <p className="text-muted-foreground">Saved weights add up to {sum}. A cycle can only be published when they add up to exactly 100; publishing freezes the template.</p>
              <PublishButton cycleId={cycleId} />
            </>
          ) : (
            <table className="w-full" data-testid="competency-table">
              <tbody>
                {(competencies ?? []).map((c) => (
                  <tr key={c.id} className="border-b">
                    <td className="py-1">{c.name}</td>
                    <td className="py-1 text-right tabular-nums">{Number(c.weight_pct)}%</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </CardContent>
      </Card>

      {report && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Cycle report</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <div className="grid gap-3 sm:grid-cols-4" data-testid="cycle-report">
              <p>
                <span className="text-muted-foreground">Eligible staff</span>
                <br />
                <strong data-testid="report-eligible">{report.eligible}</strong>
              </p>
              <p>
                <span className="text-muted-foreground">Average score</span>
                <br />
                <strong>{report.average_score === null ? '—' : Number(report.average_score).toFixed(2)}</strong>
              </p>
              <p>
                <span className="text-muted-foreground">Awaiting acknowledgement</span>
                <br />
                <strong>{report.awaiting_acknowledgement}</strong>
              </p>
              <p>
                <span className="text-muted-foreground">Final</span>
                <br />
                <strong>{report.final}</strong>
              </p>
            </div>
            {report.excluded_count > 0 && (
              <p className="text-muted-foreground" data-testid="report-excluded">
                Not in this cycle (under {report.min_service_days} days of service at {report.closes_on}): {report.excluded.map((e) => `${e.name} (${e.service_days} days)`).join(', ')}. They are left out of every figure above.
              </p>
            )}
          </CardContent>
        </Card>
      )}

      {(appraisals ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Appraisals</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm" data-testid="appraisal-list">
            {(appraisals ?? []).map((a) => (
              <div key={a.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="appraisal-row">
                <span>
                  <Link href={`/staff/appraisals/${a.id}`} className="font-medium underline">
                    {one(a.staff)?.full_name}
                  </Link>{' '}
                  <span className="text-xs text-muted-foreground">rated by {raterName.get(a.rater_id) ?? '—'}</span>
                </span>
                <span className="flex items-center gap-2">
                  {a.total_score !== null && <strong>{Number(a.total_score).toFixed(2)}</strong>}
                  <Badge variant="outline">{a.status.replace(/_/g, ' ')}</Badge>
                </span>
              </div>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
