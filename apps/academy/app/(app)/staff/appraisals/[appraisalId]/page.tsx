import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { AckForm, FinaliseButton, ScoreForm } from '../appraisal-forms';

export const dynamic = 'force-dynamic';

type Snapshot = { id: string; name: string; weight_pct: number }[];

export default async function AppraisalPage({ params }: { params: Promise<{ appraisalId: string }> }) {
  const { appraisalId } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(appraisalId)) notFound();
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  // Row-level security decides whether this person may see the appraisal at all: the rater, HR and the
  // Owner always; the staff member only once it has been released.
  const { data: a } = await supabase
    .from('appraisal')
    .select('id, status, total_score, rater_id, template_snapshot, released_at, acknowledged_at, appraisee_comment, cycle_id, staff:staff_id(full_name, employee_code, user_id)')
    .eq('id', appraisalId)
    .maybeSingle();
  if (!a) notFound();
  const staff = one(a.staff);
  const snapshot = (a.template_snapshot ?? []) as unknown as Snapshot;
  const { data: scoreRows } = await supabase.from('appraisal_score').select('competency_id, rating').eq('appraisal_id', appraisalId);
  const ratings = Object.fromEntries((scoreRows ?? []).map((s) => [s.competency_id, s.rating]));

  const isRater = actor?.userId === a.rater_id;
  const isAppraisee = staff?.user_id === actor?.userId;
  const canClose = isHrWriter(actor?.role) && (a.status === 'released' || a.status === 'awaiting_acknowledgement');
  const open = a.status === 'in_progress';
  const canRespond = isAppraisee && (a.status === 'released' || a.status === 'awaiting_acknowledgement');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold" data-testid="appraisal-staff">
            Appraisal: {staff?.full_name}
          </h1>
          <p className="text-sm text-muted-foreground">{staff?.employee_code}</p>
          <p className="text-sm">
            <Link href="/staff/appraisals" className="underline">
              Back to appraisals
            </Link>
          </p>
        </div>
        <Badge variant={a.status === 'final' ? 'success' : 'warning'} data-testid="appraisal-status">
          {a.status.replace(/_/g, ' ')}
        </Badge>
      </div>

      {open && isRater && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Rate each competency from 1 to 5</CardTitle>
          </CardHeader>
          <CardContent>
            <ScoreForm appraisalId={appraisalId} competencies={snapshot} existing={ratings} />
          </CardContent>
        </Card>
      )}

      {open && !isRater && <p className="text-sm text-muted-foreground">This appraisal is still being prepared by the rater. Nothing is shown to the staff member until it is released.</p>}

      {!open && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Scores</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <table className="w-full" data-testid="score-table">
              <thead>
                <tr className="border-b text-left text-muted-foreground">
                  <th className="py-1">Competency</th>
                  <th className="py-1 text-right">Weight</th>
                  <th className="py-1 text-right">Rating (of 5)</th>
                </tr>
              </thead>
              <tbody>
                {snapshot.map((c) => (
                  <tr key={c.id} className="border-b">
                    <td className="py-1">{c.name}</td>
                    <td className="py-1 text-right tabular-nums">{Number(c.weight_pct)}%</td>
                    <td className="py-1 text-right tabular-nums">{ratings[c.id] ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
            <p className="text-base font-semibold" data-testid="appraisal-total">
              Total: {a.total_score === null ? '—' : Number(a.total_score).toFixed(2)} of 100
            </p>
            {a.acknowledged_at && <p className="text-muted-foreground">Acknowledged {new Date(a.acknowledged_at).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}.</p>}
            {a.appraisee_comment && (
              <div className="rounded-md border p-3" data-testid="appraisee-comment">
                <p className="text-xs font-medium text-muted-foreground">Response from {staff?.full_name}</p>
                <p className="whitespace-pre-wrap">{a.appraisee_comment}</p>
              </div>
            )}
          </CardContent>
        </Card>
      )}

      {canRespond && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Your response</CardTitle>
          </CardHeader>
          <CardContent>
            <AckForm appraisalId={appraisalId} canAcknowledge />
          </CardContent>
        </Card>
      )}

      {canClose && !isAppraisee && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Close this appraisal</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p className="text-muted-foreground">Use this once the staff member&apos;s response has been heard. The score is not changed.</p>
            <FinaliseButton appraisalId={appraisalId} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
