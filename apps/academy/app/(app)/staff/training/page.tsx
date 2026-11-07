import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDatePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { ProgramForm } from './program-form';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'hr_manager'];

export default async function TrainingPage({ searchParams }: { searchParams: Promise<{ year?: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const thisYear = new Date().getFullYear();
  const year = Math.min(Math.max(Number((await searchParams).year) || thisYear, 2000), thisYear + 1);

  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const [{ data: cpd }, { data: programs }, { data: staff }] = await Promise.all([
    supabase.rpc('staff_cpd_hours', { p_campus_id: campus.id, p_year: year }),
    supabase.from('training_program').select('id, title, provider, held_on, hours, is_mandatory, training_attendance(staff_id)').eq('campus_id', campus.id).order('held_on', { ascending: false }).limit(50),
    supabase.from('staff').select('id, full_name').eq('campus_id', campus.id).eq('employment_status', 'active').order('full_name'),
  ]);

  return (
    <>
      <PageHeader title="Staff training" description="Record workshops and courses, who attended, and each person's CPD hours for the year." />
      <div className="grid gap-6 lg:grid-cols-[1fr_24rem]">
        <div className="space-y-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">CPD hours in {year}</CardTitle>
            </CardHeader>
            <CardContent>
              <form method="get" className="mb-3 flex items-center gap-2 text-sm">
                <label htmlFor="cpd-year">Year</label>
                <input id="cpd-year" name="year" type="number" defaultValue={year} className="h-9 w-24 rounded-md border bg-background px-2" />
                <button type="submit" className="h-9 rounded-md border px-3">
                  Show
                </button>
              </form>
              {(cpd ?? []).length === 0 ? (
                <p className="text-sm text-muted-foreground">No active staff on this campus.</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Staff</TableHead>
                      <TableHead className="text-right">Hours</TableHead>
                      <TableHead className="text-right">Programs</TableHead>
                      <TableHead>Mandatory</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(cpd ?? []).map((c) => (
                      <TableRow key={c.staff_id} data-testid="cpd-row">
                        <TableCell>{c.full_name}</TableCell>
                        <TableCell className="text-right">{Number(c.hours)}</TableCell>
                        <TableCell className="text-right">{c.programs}</TableCell>
                        <TableCell>{c.mandatory_missed > 0 ? <Badge variant="warning">{c.mandatory_missed} missed</Badge> : <Badge variant="success">Up to date</Badge>}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Programs</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2 text-sm">
              {(programs ?? []).length === 0 && <p className="text-muted-foreground">None recorded yet.</p>}
              {(programs ?? []).map((p) => (
                <div key={p.id} className="flex flex-wrap justify-between gap-2 border-b pb-2">
                  <span>
                    <span className="font-medium">{p.title}</span>
                    {p.provider ? ` · ${p.provider}` : ''} {p.is_mandatory && <Badge variant="outline">mandatory</Badge>}
                  </span>
                  <span className="text-muted-foreground">
                    {formatDatePk(p.held_on)} · {Number(p.hours)} h · {(p.training_attendance ?? []).length} attended
                  </span>
                </div>
              ))}
            </CardContent>
          </Card>
        </div>
        <ProgramForm campusId={campus.id} staff={(staff ?? []).map((s) => ({ id: s.id, name: s.full_name }))} />
      </div>
    </>
  );
}
