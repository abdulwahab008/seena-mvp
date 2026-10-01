import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, isHrWriter, one } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CreateCycleForm } from './appraisal-forms';

export const dynamic = 'force-dynamic';

const STATUS_LABEL: Record<string, string> = {
  in_progress: 'In progress', released: 'Released', awaiting_acknowledgement: 'Awaiting acknowledgement', final: 'Final',
  draft: 'Draft', published: 'Published', closed: 'Closed',
};
const STATUS_VARIANT: Record<string, 'info' | 'warning' | 'success' | 'outline'> = {
  in_progress: 'info', released: 'warning', awaiting_acknowledgement: 'warning', final: 'success', draft: 'outline', published: 'success', closed: 'outline',
};

export default async function AppraisalsPage() {
  const actor = await getCurrentActor();
  const supabase = await supabaseServer();
  const canManage = isHrWriter(actor?.role);
  const canSeeCycles = canManage || actor?.role === 'principal';

  const [{ data: cycles }, { data: sessions }, { data: rows }] = await Promise.all([
    canSeeCycles ? supabase.from('appraisal_cycle').select('id, name, opens_on, closes_on, status, min_service_days').order('closes_on', { ascending: false }) : Promise.resolve({ data: [] as { id: string; name: string; opens_on: string; closes_on: string; status: string; min_service_days: number }[] }),
    canManage ? supabase.from('academic_session').select('id, name').order('name', { ascending: false }) : Promise.resolve({ data: [] as { id: string; name: string }[] }),
    supabase.from('appraisal').select('id, status, total_score, rater_id, cycle_id, staff:staff_id(full_name, user_id)').order('created_at', { ascending: false }).limit(300),
  ]);

  const mine = (rows ?? []).filter((r) => one(r.staff)?.user_id === actor?.userId);
  const toRate = (rows ?? []).filter((r) => r.rater_id === actor?.userId && one(r.staff)?.user_id !== actor?.userId);
  const cycleName = new Map((cycles ?? []).map((c) => [c.id, c.name]));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff appraisals</h1>
        <p className="text-sm text-muted-foreground">
          FR-D14 — one weighted appraisal per staff member each session. Scores stay hidden from the staff member until the rater releases them; their acknowledgement or response is recorded.
        </p>
      </div>

      {toRate.length > 0 && (
        <Card data-testid="to-rate">
          <CardHeader>
            <CardTitle className="text-base">Appraisals you rate</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            {toRate.map((r) => (
              <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="rate-row">
                <Link href={`/staff/appraisals/${r.id}`} className="font-medium underline">
                  {one(r.staff)?.full_name}
                </Link>
                <Badge variant={STATUS_VARIANT[r.status] ?? 'outline'}>{STATUS_LABEL[r.status] ?? r.status}</Badge>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {mine.length > 0 && (
        <Card data-testid="my-appraisals">
          <CardHeader>
            <CardTitle className="text-base">My appraisals</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            {mine.map((r) => (
              <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2">
                <Link href={`/staff/appraisals/${r.id}`} className="font-medium underline" data-testid="my-appraisal-link">
                  {cycleName.get(r.cycle_id) ?? 'Appraisal'}
                </Link>
                <Badge variant={STATUS_VARIANT[r.status] ?? 'outline'}>{STATUS_LABEL[r.status] ?? r.status}</Badge>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {canSeeCycles && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Appraisal cycles</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm" data-testid="cycle-list">
            {(cycles ?? []).length === 0 && <p className="text-muted-foreground">No cycle has been created.</p>}
            {(cycles ?? []).map((c) => (
              <div key={c.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="cycle-row">
                <span>
                  {canManage ? (
                    <Link href={`/staff/appraisals/cycles/${c.id}`} className="font-medium underline">
                      {c.name}
                    </Link>
                  ) : (
                    <span className="font-medium">{c.name}</span>
                  )}{' '}
                  <span className="text-xs text-muted-foreground">
                    {c.opens_on} to {c.closes_on} · minimum service {c.min_service_days} days
                  </span>
                </span>
                <Badge variant={STATUS_VARIANT[c.status] ?? 'outline'}>{STATUS_LABEL[c.status] ?? c.status}</Badge>
              </div>
            ))}
          </CardContent>
        </Card>
      )}

      {canManage && (sessions ?? []).length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">New appraisal cycle</CardTitle>
          </CardHeader>
          <CardContent>
            <CreateCycleForm sessions={(sessions ?? []).map((s) => ({ id: s.id, name: s.name }))} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
