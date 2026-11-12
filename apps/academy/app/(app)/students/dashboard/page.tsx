import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { todayPk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Breakdown, KpiGrid } from '@/components/module-dashboard';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'admissions_officer', 'receptionist'];
const GENDERS = [
  { value: 'male', label: 'Boys' },
  { value: 'female', label: 'Girls' },
  { value: 'other', label: 'Other' },
] as const;

// PostgREST cannot filter on the day and month of a date, so today's birthdays are matched against
// today's date in every plausible birth year. A 29 February birthday has no match in other years.
function birthdayDates(today: string): string[] {
  const year = Number(today.slice(0, 4));
  const monthDay = today.slice(4);
  const dates: string[] = [];
  for (let y = year - 30; y <= year - 1; y++) {
    const d = `${y}${monthDay}`;
    if (new Date(`${d}T00:00:00Z`).toISOString().slice(0, 10) === d) dates.push(d);
  }
  return dates;
}

export default async function StudentsDashboardPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const today = todayPk();
  const monthStart = `${today.slice(0, 8)}01`;
  const activeEnrolments = () => supabase.from('enrolment').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).eq('status', 'active').is('deleted_at', null);

  const [active, admitted, withdrawn, { data: classes }, { data: birthdays }, ...genders] = await Promise.all([
    activeEnrolments(),
    supabase.from('enrolment').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).gte('joined_on', monthStart).lte('joined_on', today).is('deleted_at', null),
    supabase.from('enrolment').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).in('status', ['left', 'transferred']).gte('left_on', monthStart).lte('left_on', today).is('deleted_at', null),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('student').select('id, name_en, gr_number').eq('campus_id', campus.id).eq('status', 'active').is('deleted_at', null).in('dob', birthdayDates(today)).order('name_en'),
    ...GENDERS.map((g) =>
      supabase.from('enrolment').select('id, student!inner(gender)', { count: 'exact', head: true }).eq('campus_id', campus.id).eq('status', 'active').is('deleted_at', null).eq('student.gender', g.value),
    ),
  ]);
  const perClass = await Promise.all((classes ?? []).map((c) => activeEnrolments().eq('class_level_id', c.id)));

  const classRows = (classes ?? []).map((c, i) => ({ key: c.id, label: c.name_en, value: perClass[i]?.count ?? 0, href: `/students?cls=c:${c.id}` })).filter((r) => r.value > 0);
  const genderRows = GENDERS.map((g, i) => ({ key: g.value, label: g.label, value: genders[i]?.count ?? 0, href: `/students?gender=${g.value}` })).filter((r) => r.key !== 'other' || r.value > 0);

  return (
    <>
      <PageHeader title="Students dashboard" description={`Enrolment, admissions and withdrawals this month at ${campus.name}.`} />
      <KpiGrid
        prefix="students"
        kpis={[
          { id: 'active', label: 'Active students', value: active.count ?? 0 },
          { id: 'admitted', label: 'Admitted this month', value: admitted.count ?? 0 },
          { id: 'withdrawn', label: 'Withdrawn this month', value: withdrawn.count ?? 0 },
          { id: 'birthdays', label: 'Birthdays today', value: (birthdays ?? []).length },
        ]}
      />
      <div className="mt-6 grid items-start gap-4 lg:grid-cols-3">
        <Breakdown title="Students per class" rows={classRows} empty="No active students yet." bars />
        <Breakdown title="Boys and girls" rows={genderRows} empty="No active students yet." bars />
        <Card className="self-start">
          <CardHeader className="p-4 pb-2">
            <CardTitle className="text-base">Birthdays today</CardTitle>
          </CardHeader>
          <CardContent className="p-2 pt-0">
            {(birthdays ?? []).length === 0 ? (
              <p className="px-2 pb-2 text-sm text-muted-foreground">None today.</p>
            ) : (
              (birthdays ?? []).map((s) => (
                <Link key={s.id} href={`/students/${s.id}`} className="block rounded-md px-2 py-1.5 text-sm hover:bg-muted" data-testid="students-birthday">
                  {s.name_en} <span className="text-muted-foreground">· GR {s.gr_number}</span>
                </Link>
              ))
            )}
          </CardContent>
        </Card>
      </div>
    </>
  );
}
