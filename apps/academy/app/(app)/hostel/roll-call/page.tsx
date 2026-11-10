import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { EmptyState } from '@/components/ui/empty-state';
import { Stat } from '@/components/ui/page-header';
import { Button } from '@/components/ui/button';
import { RollCallForm, type Resident } from './roll-call-form';
import { ROLL_SESSIONS } from './statuses';

export const dynamic = 'force-dynamic';

export default async function HostelRollCallPage({ searchParams }: { searchParams: Promise<{ date?: string; session?: string }> }) {
  const f = await searchParams;
  const today = todayPk();
  const date = f.date && /^\d{4}-\d{2}-\d{2}$/.test(f.date) && f.date <= today ? f.date : today;
  const session = f.session === 'morning' ? 'morning' : 'night';

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: allocations }, { data: marks }] = await Promise.all([
    supabase
      .from('hostel_allocation')
      .select('student:student_id(id, name_en, gr_number), bed:bed_id(bed_code, room:room_id(block:block_id(name)))')
      .eq('campus_id', campus.id)
      .lte('starts_on', date)
      .or(`ends_on.is.null,ends_on.gte.${date}`),
    supabase.from('hostel_roll_call').select('student_id, status').eq('campus_id', campus.id).eq('roll_date', date).eq('session', session),
  ]);
  const byStudent = new Map((marks ?? []).map((m) => [m.student_id, m.status]));
  const residents: Resident[] = (allocations ?? [])
    .flatMap((a): Resident[] => {
      const s = one(a.student);
      const bed = one(a.bed);
      if (!s) return [];
      const status = byStudent.get(s.id);
      return [{ studentId: s.id, name: s.name_en, gr: s.gr_number, bed: bed?.bed_code ?? '', block: one(one(bed?.room)?.block)?.name ?? '', status: status === 'present' || status === 'absent' || status === 'on_leave' ? status : null }];
    })
    .sort((a, b) => a.bed.localeCompare(b.bed, undefined, { numeric: true }));
  const count = (st: string) => (marks ?? []).filter((m) => m.status === st).length;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Hostel roll call</h1>
        <p className="text-sm text-muted-foreground">Morning and night attendance of residents at {campus.name}.</p>
      </div>
      <div className="flex flex-wrap items-end gap-4">
        <nav className="flex gap-2" aria-label="Session">
          {ROLL_SESSIONS.map((s) => (
            <Link
              key={s}
              href={`/hostel/roll-call?date=${date}&session=${s}`}
              aria-current={s === session ? 'page' : undefined}
              className={cn('rounded-full border px-3 py-1 text-sm capitalize', s === session ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted')}
            >
              {s}
            </Link>
          ))}
        </nav>
        <form method="get" className="flex items-end gap-2 text-sm">
          <input type="hidden" name="session" value={session} />
          <input type="date" name="date" defaultValue={date} max={today} aria-label="Date" className="h-9 rounded-md border bg-background px-2" />
          <Button type="submit" size="sm" variant="outline">
            Show
          </Button>
        </form>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-4">
        <Stat label="Residents" value={residents.length} />
        <Stat label="Present" value={count('present')} tone="success" />
        <Stat label="Absent" value={count('absent')} tone={count('absent') > 0 ? 'destructive' : 'default'} />
        <Stat label="On leave" value={count('on_leave')} />
      </section>
      {residents.length === 0 ? (
        <EmptyState title="No residents" description="Allocate beds under Bed Allocation first." />
      ) : (
        <RollCallForm key={`${date}-${session}`} campusId={campus.id} date={date} session={session} residents={residents} />
      )}
    </div>
  );
}
