import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { loadAdmissionRegister, parseRegisterFilters } from './register';

export const dynamic = 'force-dynamic';

export default async function AdmissionRegisterPage({ searchParams }: { searchParams: Promise<{ session?: string; class?: string }> }) {
  const filters = parseRegisterFilters(await searchParams);
  const supabase = await supabaseServer();
  const [{ data: rows, error }, { data: sessions }, { data: classes }] = await Promise.all([
    loadAdmissionRegister(filters),
    supabase.from('academic_session').select('id, name').order('starts_on', { ascending: false }),
    supabase.from('class_level').select('id, name_en').order('ordinal'),
  ]);
  const query = new URLSearchParams(Object.entries(filters).filter((e): e is [string, string] => Boolean(e[1]))).toString();

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Admission register</h1>
          <p className="text-sm text-muted-foreground">Every student by GR number with the date and class of admission, and the date and reason of leaving.</p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Button asChild size="sm" variant="outline">
            <a href={`/students/admission-register/csv${query ? `?${query}` : ''}`} data-testid="register-csv">
              Download CSV
            </a>
          </Button>
          <PrintButton />
        </div>
      </div>
      <form method="get" className="flex flex-wrap items-end gap-2 text-sm print:hidden">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Admitted in session</span>
          <select name="session" defaultValue={filters.session ?? ''} className="h-9 rounded-md border bg-background px-2">
            <option value="">All sessions</option>
            {(sessions ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Admitted to class</span>
          <select name="class" defaultValue={filters.class ?? ''} className="h-9 rounded-md border bg-background px-2">
            <option value="">All classes</option>
            {(classes ?? []).map((c) => (
              <option key={c.id} value={c.id}>
                {c.name_en}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
        {query && (
          <Link href="/students/admission-register" className="h-9 px-2 leading-9 text-muted-foreground underline">
            Clear
          </Link>
        )}
      </form>
      {error ? (
        <p className="text-sm text-destructive">{error.message.includes('FORBIDDEN') ? 'You do not have access to the admission register.' : 'Could not load the register. Try again.'}</p>
      ) : (rows ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No students match these filters.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>GR no.</TableHead>
              <TableHead>Admitted</TableHead>
              <TableHead>Name</TableHead>
              <TableHead>Father name</TableHead>
              <TableHead>Date of birth</TableHead>
              <TableHead>Class admitted to</TableHead>
              <TableHead>Withdrawn</TableHead>
              <TableHead>Reason</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(rows ?? []).map((r) => (
              <TableRow key={r.student_id} data-testid="register-row">
                <TableCell className="font-medium">{r.gr_number}</TableCell>
                <TableCell>{formatDatePk(r.admitted_on)}</TableCell>
                <TableCell>
                  <Link href={`/students/${r.student_id}`} className="hover:underline">
                    {r.name_en}
                  </Link>
                </TableCell>
                <TableCell>{r.father_name_en ?? ''}</TableCell>
                <TableCell>{formatDatePk(r.dob)}</TableCell>
                <TableCell>{r.class_admitted ?? ''}</TableCell>
                <TableCell>{r.withdrawn_on ? formatDatePk(r.withdrawn_on) : ''}</TableCell>
                <TableCell>{r.withdrawal_reason ?? ''}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
