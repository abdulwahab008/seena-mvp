import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk, todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { VaccinationForm } from './vaccination-form';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

function addDays(date: string, days: number) {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export default async function VaccinationsPage() {
  const supabase = await supabaseServer();
  const today = todayPk();
  const [{ data: due }, { data: recent }] = await Promise.all([
    supabase
      .from('student_vaccination')
      .select('id, vaccine, dose_no, due_on, student(name_en, gr_number)')
      .is('given_on', null)
      .lte('due_on', addDays(today, 30))
      .order('due_on'),
    supabase
      .from('student_vaccination')
      .select('id, vaccine, dose_no, given_on, notes, student(name_en, gr_number)')
      .not('given_on', 'is', null)
      .order('given_on', { ascending: false })
      .limit(50),
  ]);
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Vaccinations</h1>
        <p className="text-sm text-muted-foreground">Doses due in the next 30 days or overdue, and doses given. Record a dose as due, as given, or both.</p>
      </div>
      <VaccinationForm />
      <section className="space-y-2">
        <h2 className="font-medium">Due and overdue</h2>
        {(due ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">Nothing due in the next 30 days.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Student</TableHead>
                <TableHead>Vaccine</TableHead>
                <TableHead>Dose</TableHead>
                <TableHead>Due</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {(due ?? []).map((v) => {
                const s = one(v.student);
                const overdue = v.due_on !== null && v.due_on < today;
                return (
                  <TableRow key={v.id} data-testid="vaccination-due">
                    <TableCell>
                      {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                    </TableCell>
                    <TableCell>{v.vaccine}</TableCell>
                    <TableCell>{v.dose_no}</TableCell>
                    <TableCell className={cn(overdue && 'font-medium text-destructive')}>
                      {v.due_on ? formatDatePk(v.due_on) : ''}
                      {overdue ? ' (overdue)' : ''}
                    </TableCell>
                  </TableRow>
                );
              })}
            </TableBody>
          </Table>
        )}
      </section>
      <section className="space-y-2">
        <h2 className="font-medium">Recently given</h2>
        {(recent ?? []).length === 0 ? (
          <p className="text-sm text-muted-foreground">No doses recorded yet.</p>
        ) : (
          <ul className="space-y-1 text-sm">
            {(recent ?? []).map((v) => {
              const s = one(v.student);
              return (
                <li key={v.id} data-testid="vaccination-given">
                  {formatDatePk(v.given_on!)} · {s?.name_en} ({s?.gr_number}) · {v.vaccine} dose {v.dose_no}
                  {v.notes ? ` · ${v.notes}` : ''}
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
