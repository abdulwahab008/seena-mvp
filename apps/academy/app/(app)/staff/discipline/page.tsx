import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export const dynamic = 'force-dynamic';

export default async function DisciplineWorklistPage() {
  const actor = await getCurrentActor();
  if (actor?.role !== 'hr_manager' && actor?.role !== 'owner') {
    return (
      <div className="space-y-2">
        <h1 className="text-2xl font-semibold">Disciplinary worklist</h1>
        <p className="text-sm text-muted-foreground">The disciplinary record is restricted to HR and the Owner.</p>
      </div>
    );
  }
  const supabase = await supabaseServer();
  const { data: overdue } = await supabase.rpc('list_overdue_showcause');
  const { data: suspensions } = await supabase.from('staff_suspension').select('id, staff_id, from_date, to_date, disciplinary_id, staff:staff_id(full_name)').order('from_date', { ascending: false }).limit(50);
  const { data: superseding } = await supabase.from('staff_disciplinary').select('supersedes_id').not('supersedes_id', 'is', null);
  const closed = new Set((superseding ?? []).map((s) => s.supersedes_id));
  const inForce = (suspensions ?? []).filter((s) => !closed.has(s.disciplinary_id));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Disciplinary worklist</h1>
        <p className="text-sm text-muted-foreground">
          FR-D15 — a show-cause notice is overdue from the day its response deadline is reached. Entries are permanent; corrections are added as new entries.
        </p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Overdue show-cause notices</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="overdue-list">
          {(overdue ?? []).length === 0 && <p className="text-muted-foreground">No show-cause notice is waiting for a response.</p>}
          {(overdue ?? []).map((o) => (
            <div key={o.disciplinary_id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="overdue-row">
              <span>
                <Link href={`/staff/${o.staff_id}`} className="font-medium underline">
                  {o.staff_name}
                </Link>{' '}
                <span className="text-xs text-muted-foreground">({o.employee_code}) · issued {o.issued_on} · due {o.response_due_on}</span>
              </span>
              <Badge variant="destructive">{o.days_overdue === 0 ? 'due today' : `${o.days_overdue} day(s) overdue`}</Badge>
            </div>
          ))}
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <CardTitle className="text-base">Suspensions</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm">
          {inForce.length === 0 && <p className="text-muted-foreground">No suspension is recorded.</p>}
          {inForce.map((s) => (
            <div key={s.id} className="border-b pb-2">
              <Link href={`/staff/${s.staff_id}`} className="font-medium underline">
                {(Array.isArray(s.staff) ? s.staff[0] : s.staff)?.full_name}
              </Link>{' '}
              <span className="text-xs text-muted-foreground">
                {s.from_date} to {s.to_date}: read-only; their periods appear in the Substitutions feed
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
