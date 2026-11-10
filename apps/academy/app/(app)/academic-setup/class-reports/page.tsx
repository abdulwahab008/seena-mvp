import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { allRows } from '@/lib/supabase/all-rows';
import { PrintButton } from '@/components/print-button';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
const OTHER_REPORTS = [
  { href: '/students/reports/strength', label: 'Class strength report (boys and girls by section)' },
  { href: '/fees/structure', label: 'Class fee structure' },
  { href: '/exams/seating', label: 'Exam seating plan' },
  { href: '/academic-setup/timetable', label: 'Class timetables' },
];

export default async function ClassReportsPage() {
  const supabase = await supabaseServer();
  const [{ data: sections }, { data: enrolments }] = await Promise.all([
    supabase.from('class_section').select('id, name, capacity, class_level:class_level_id(name_en, ordinal)').eq('is_active', true),
    allRows((from, to) => supabase.from('enrolment').select('section_id').eq('status', 'active').is('deleted_at', null).order('id').range(from, to)),
  ]);
  const filled = new Map<string, number>();
  for (const e of enrolments) filled.set(e.section_id, (filled.get(e.section_id) ?? 0) + 1);
  const rows = (sections ?? [])
    .map((s) => ({ id: s.id, cls: one(s.class_level)?.name_en ?? '', ordinal: one(s.class_level)?.ordinal ?? 0, section: s.name, capacity: s.capacity, filled: filled.get(s.id) ?? 0 }))
    .sort((a, b) => a.ordinal - b.ordinal || a.section.localeCompare(b.section));
  const totals = rows.reduce((t, r) => ({ capacity: t.capacity + r.capacity, filled: t.filled + r.filled }), { capacity: 0, filled: 0 });

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Class reports</h1>
          <p className="text-sm text-muted-foreground">Seats filled against capacity in every section, and printable class lists.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Capacity and vacancy</h2>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No active sections yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Class</TableHead>
                <TableHead>Section</TableHead>
                <TableHead className="text-right">Capacity</TableHead>
                <TableHead className="text-right">Filled</TableHead>
                <TableHead className="text-right">Vacant</TableHead>
                <TableHead className="text-right print:hidden">Class list</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.id} data-testid="capacity-row">
                  <TableCell className="font-medium">{r.cls}</TableCell>
                  <TableCell>{r.section}</TableCell>
                  <TableCell className="tabular text-right">{r.capacity}</TableCell>
                  <TableCell className="tabular text-right">{r.filled}</TableCell>
                  <TableCell className={`tabular text-right ${r.filled > r.capacity ? 'font-medium text-destructive' : ''}`}>{r.capacity - r.filled}</TableCell>
                  <TableCell className="text-right print:hidden">
                    <Link href={`/academic-setup/class-reports/class-list?section=${r.id}`} className="text-sm font-medium text-primary hover:underline">
                      View
                    </Link>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
            <TableFooter>
              <TableRow>
                <TableCell colSpan={2}>Total</TableCell>
                <TableCell className="tabular text-right">{totals.capacity}</TableCell>
                <TableCell className="tabular text-right">{totals.filled}</TableCell>
                <TableCell className="tabular text-right">{totals.capacity - totals.filled}</TableCell>
                <TableCell className="print:hidden" />
              </TableRow>
            </TableFooter>
          </Table>
        )}
      </section>

      <section className="space-y-2 print:hidden">
        <h2 className="text-lg font-semibold">More class reports</h2>
        <ul className="divide-y rounded-lg border">
          {OTHER_REPORTS.map((r) => (
            <li key={r.href} className="flex items-center justify-between px-4 py-2.5 text-sm">
              {r.label}
              <Link href={r.href} className="font-medium text-primary hover:underline">
                View
              </Link>
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
