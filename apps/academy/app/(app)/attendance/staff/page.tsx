import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { todayPk } from '@/lib/dates';
import { EmptyState } from '@/components/ui/empty-state';
import { Stat } from '@/components/ui/page-header';
import { Button } from '@/components/ui/button';
import { StaffRegister, type StaffMark } from './staff-register';

export const dynamic = 'force-dynamic';

const MARKING_ROLES = ['super_admin', 'owner', 'principal', 'hr_manager'];

export default async function StaffAttendancePage({ searchParams }: { searchParams: Promise<{ date?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !MARKING_ROLES.includes(actor.role)) notFound();
  const raw = (await searchParams).date;
  const date = raw && /^\d{4}-\d{2}-\d{2}$/.test(raw) ? raw : todayPk();

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: staffRows }, { data: marks }] = await Promise.all([
    supabase.from('staff').select('id, full_name, employee_code, designation:designation_id(name_en)').eq('campus_id', campus.id).eq('employment_status', 'active').order('full_name'),
    supabase.from('staff_attendance').select('staff_id, status, source').eq('campus_id', campus.id).eq('att_date', date),
  ]);
  const byStaff = new Map((marks ?? []).map((m) => [m.staff_id, m]));
  const staff: StaffMark[] = (staffRows ?? []).map((s) => ({
    id: s.id,
    name: s.full_name,
    code: s.employee_code,
    designation: one(s.designation)?.name_en ?? null,
    status: byStaff.get(s.id)?.status ?? null,
    source: byStaff.get(s.id)?.source ?? null,
  }));
  const count = (st: string) => (marks ?? []).filter((m) => m.status === st).length;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Staff attendance</h1>
        <p className="text-sm text-muted-foreground">Mark daily attendance for {campus.name}. Approved leave and biometric punches are kept.</p>
      </div>
      <form method="get" className="flex items-end gap-2 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Date</span>
          <input type="date" name="date" defaultValue={date} max={todayPk()} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <Button type="submit" size="sm" variant="outline">
          Show
        </Button>
      </form>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-5">
        <Stat label="Present" value={count('present')} tone="success" />
        <Stat label="Late" value={count('late')} tone="warning" />
        <Stat label="Half day" value={count('half_day')} />
        <Stat label="On leave" value={count('on_leave')} />
        <Stat label="Absent" value={count('absent')} tone={count('absent') > 0 ? 'destructive' : 'default'} />
      </section>
      {staff.length === 0 ? (
        <EmptyState title="No active staff" description="Register staff under Staff first." />
      ) : (
        <StaffRegister key={date} campusId={campus.id} date={date} staff={staff} />
      )}
    </div>
  );
}
