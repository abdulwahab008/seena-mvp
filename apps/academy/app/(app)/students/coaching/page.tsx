import { supabaseServer } from '@/lib/supabase/server';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDatePk } from '@/lib/dates';
import { pkr } from '@/lib/rpc-action';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { BatchForm, CoachingEnrolForm, EditBatchButton, EndEnrolmentButton, PostChargesForm } from './coaching-forms';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function CoachingPage() {
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <p className="text-sm text-muted-foreground">No campus is assigned to you.</p>;

  const [{ data: batches }, { data: enrolments }, { data: staff }] = await Promise.all([
    supabase
      .from('coaching_batch')
      .select('id, name, subject, teacher_staff_id, monthly_fee_paisa, schedule, is_active, staff(full_name)')
      .eq('campus_id', campus.id)
      .order('is_active', { ascending: false })
      .order('name'),
    supabase
      .from('coaching_enrolment')
      .select('id, batch_id, starts_on, student(name_en, gr_number)')
      .eq('campus_id', campus.id)
      .is('ends_on', null)
      .order('starts_on', { ascending: false }),
    supabase.from('staff').select('id, full_name').eq('campus_id', campus.id).eq('employment_status', 'active').order('full_name'),
  ]);
  const staffOptions = (staff ?? []).map((s) => ({ id: s.id, label: s.full_name }));
  const batchName = new Map((batches ?? []).map((b) => [b.id, b.name]));
  const countByBatch = new Map<string, number>();
  for (const e of enrolments ?? []) countByBatch.set(e.batch_id, (countByBatch.get(e.batch_id) ?? 0) + 1);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Extra coaching</h1>
          <p className="text-sm text-muted-foreground">
            Paid classes outside the timetable. Post a month&apos;s coaching fees before generating that month&apos;s challans; each fee appears on the challan as a Coaching line.
          </p>
        </div>
        <PostChargesForm />
      </div>

      <section className="space-y-2">
        <h2 className="font-medium">Batches</h2>
        {(batches ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No coaching batches yet. Add the first one below.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Batch</TableHead>
                <TableHead>Teacher</TableHead>
                <TableHead>Schedule</TableHead>
                <TableHead className="text-right">Monthly fee</TableHead>
                <TableHead className="text-right">Students</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {(batches ?? []).map((b) => (
                <TableRow key={b.id} data-testid="coaching-batch">
                  <TableCell>
                    <span className="font-medium">{b.name}</span>
                    {b.subject && <span className="text-xs text-muted-foreground"> · {b.subject}</span>}
                    {!b.is_active && (
                      <Badge variant="outline" className="ml-2">
                        Inactive
                      </Badge>
                    )}
                  </TableCell>
                  <TableCell>{one(b.staff)?.full_name ?? 'Not assigned'}</TableCell>
                  <TableCell>{b.schedule ?? ''}</TableCell>
                  <TableCell className="text-right tabular-nums">{pkr(b.monthly_fee_paisa)}</TableCell>
                  <TableCell className="text-right tabular-nums">{countByBatch.get(b.id) ?? 0}</TableCell>
                  <TableCell className="text-right">
                    <EditBatchButton campusId={campus.id} staff={staffOptions} batch={b} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Add a batch</CardTitle>
          </CardHeader>
          <CardContent>
            <BatchForm campusId={campus.id} staff={staffOptions} />
          </CardContent>
        </Card>
      </section>

      <section className="space-y-2">
        <h2 className="font-medium">Students in coaching</h2>
        <CoachingEnrolForm batches={(batches ?? []).filter((b) => b.is_active).map((b) => ({ id: b.id, label: b.name }))} />
        {(enrolments ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No students are enrolled in coaching.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Student</TableHead>
                <TableHead>Batch</TableHead>
                <TableHead>Since</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {(enrolments ?? []).map((e) => {
                const s = one(e.student);
                return (
                  <TableRow key={e.id} data-testid="coaching-enrolment">
                    <TableCell>
                      {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                    </TableCell>
                    <TableCell>{batchName.get(e.batch_id) ?? ''}</TableCell>
                    <TableCell>{formatDatePk(e.starts_on)}</TableCell>
                    <TableCell className="text-right">
                      <EndEnrolmentButton id={e.id} />
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </section>
    </div>
  );
}
