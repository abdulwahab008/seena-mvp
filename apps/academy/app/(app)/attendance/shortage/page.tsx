import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CloseForm, RunButton } from './controls';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function ShortagePage() {
  const supabase = await supabaseServer();
  const { data: warnings } = await supabase
    .from('attendance_shortage_warning')
    .select('id, level, pct_at_warning, raised_at, last_escalated_at, status, closed_reason, enrolment:enrolment_id(student:student_id(name_en, gr_number), class_section:section_id(name, class_level(name_en)))')
    .order('status')
    .order('level', { ascending: false })
    .limit(100);
  const open = (warnings ?? []).filter((w) => w.status === 'open');
  const closed = (warnings ?? []).filter((w) => w.status !== 'open').slice(0, 20);

  const row = (w: NonNullable<typeof warnings>[number]) => {
    const e = one(w.enrolment);
    const student = e ? one(e.student) : null;
    const section = e ? one(e.class_section) : null;
    const level = section ? one(section.class_level) : null;
    return { student, label: `${level?.name_en ?? ''} ${section?.name ?? ''}`.trim() };
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h1 className="text-2xl font-semibold">Attendance shortage warnings</h1>
          <p className="text-sm text-muted-foreground">
            FR-G16 — evaluated every Saturday evening. A student below the campus minimum gets a level-1 warning, escalating to 2 and 3 at later weeks while still below; the parent is texted at each level and the Principal is told at level 3. Students with fewer than 20 recorded days are not evaluated.
          </p>
        </div>
        <RunButton />
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Open warnings ({open.length})</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="shortage-open">
          {open.length === 0 && <p className="text-muted-foreground">No student is below the threshold.</p>}
          {open.map((w) => {
            const r = row(w);
            return (
              <div key={w.id} className="space-y-2 border-b pb-3" data-testid="shortage-row">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium">
                    {r.student?.name_en ?? 'Student'} · GR {r.student?.gr_number ?? '—'} · {r.label}
                  </span>
                  <span className="flex items-center gap-2">
                    {w.pct_at_warning}%
                    <Badge variant={w.level === 3 ? 'destructive' : 'outline'}>Level {w.level}</Badge>
                  </span>
                </div>
                <CloseForm warningId={w.id} />
              </div>
            );
          })}
        </CardContent>
      </Card>

      {closed.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Recently closed</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm">
            {closed.map((w) => (
              <div key={w.id} className="flex justify-between border-b py-1">
                <span>{row(w).student?.name_en ?? 'Student'}</span>
                <span className="text-muted-foreground">
                  {w.status} — {w.closed_reason}
                </span>
              </div>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
