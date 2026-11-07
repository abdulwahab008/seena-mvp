import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { freeAt } from '@/lib/timetable-free';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

export const dynamic = 'force-dynamic';

const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const TEACHING_ROLES = ['principal', 'vice_principal', 'head_of_department', 'class_teacher', 'subject_teacher'];

export default async function FreePeriodsPage({ searchParams }: { searchParams: Promise<{ day?: string; period?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || ['parent', 'student'].includes(actor.role)) notFound();
  const sp = await searchParams;
  const day = Math.min(Math.max(Number(sp.day) || 1, 1), 6);
  const period = Math.min(Math.max(Number(sp.period) || 1, 1), 15);

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: busy }, { data: staffLinks }, { data: rooms }] = await Promise.all([
    supabase
      .from('timetable_slot')
      .select('staff_id, room_id, timetable_version!inner(status)')
      .eq('campus_id', campus.id)
      .eq('weekday', day)
      .eq('period_no', period)
      .eq('timetable_version.status', 'PUBLISHED'),
    supabase.from('user_campus').select('user_id, app_user:user_id(full_name, app_role, status)').eq('campus_id', campus.id).eq('is_active', true),
    supabase.from('room').select('id, code, name, capacity').eq('campus_id', campus.id).eq('is_active', true).order('code'),
  ]);

  const teachers = (staffLinks ?? [])
    .map((l) => ({ id: l.user_id, user: one(l.app_user) }))
    .filter((t) => t.user && t.user.status === 'active' && TEACHING_ROLES.includes(t.user.app_role))
    .map((t) => ({ id: t.id, name: t.user!.full_name }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const free = freeAt(teachers, rooms ?? [], busy ?? []);

  return (
    <>
      <PageHeader title="Free teachers and rooms" description="Who is not teaching, and which rooms are empty, in a given period of the published timetable." />
      <form method="get" className="mb-4 flex flex-wrap items-end gap-2 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Day</span>
          <select name="day" defaultValue={day} className="h-9 rounded-md border bg-background px-2">
            {WEEKDAYS.map((d, i) => (
              <option key={d} value={i + 1}>
                {d}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Period</span>
          <input name="period" type="number" min={1} max={15} defaultValue={period} className="h-9 w-20 rounded-md border bg-background px-2" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>
      <div className="grid gap-4 md:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              Free teachers ({free.teachers.length} of {teachers.length})
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ul className="space-y-1 text-sm" data-testid="free-teachers">
              {free.teachers.map((t) => (
                <li key={t.id}>{t.name}</li>
              ))}
              {free.teachers.length === 0 && <li className="text-muted-foreground">Everyone is teaching.</li>}
            </ul>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              Empty rooms ({free.rooms.length} of {(rooms ?? []).length})
            </CardTitle>
          </CardHeader>
          <CardContent>
            <ul className="space-y-1 text-sm" data-testid="free-rooms">
              {free.rooms.map((r) => (
                <li key={r.id}>
                  {r.code} · {r.name} · seats {r.capacity}
                </li>
              ))}
              {free.rooms.length === 0 && <li className="text-muted-foreground">Every room is in use.</li>}
            </ul>
          </CardContent>
        </Card>
      </div>
    </>
  );
}
