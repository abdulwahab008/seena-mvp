import { supabaseServer } from '@/lib/supabase/server';
import { PrintButton } from '@/components/print-button';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
type Row = { cls: string; ordinal: number; section: string; boys: number; girls: number };

export default async function StrengthReportPage() {
  const supabase = await supabaseServer();
  const counts = new Map<string, Row>();
  // ponytail: pages through enrolments 1000 at a time (the API row cap); move to an SQL aggregate if a school passes a few thousand students.
  for (let from = 0; ; from += 1000) {
    const { data } = await supabase
      .from('enrolment')
      .select('student:student_id!inner(gender), section:section_id(name), class_level:class_level_id(name_en, ordinal)')
      .eq('status', 'active')
      .is('deleted_at', null)
      .eq('student.status', 'active')
      .is('student.deleted_at', null)
      .range(from, from + 999);
    for (const e of data ?? []) {
      const cl = one(e.class_level);
      const section = one(e.section)?.name ?? '';
      const key = `${cl?.name_en}|${section}`;
      const row = counts.get(key) ?? { cls: cl?.name_en ?? '', ordinal: cl?.ordinal ?? 0, section, boys: 0, girls: 0 };
      if (one(e.student)?.gender === 'male') row.boys++;
      else row.girls++;
      counts.set(key, row);
    }
    if ((data?.length ?? 0) < 1000) break;
  }
  const rows = [...counts.values()].sort((a, b) => a.ordinal - b.ordinal || a.section.localeCompare(b.section));
  const boys = rows.reduce((s, r) => s + r.boys, 0);
  const girls = rows.reduce((s, r) => s + r.girls, 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Student strength report</h1>
          <p className="text-sm text-muted-foreground">Active students in each class and section, boys and girls.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No students are enrolled in a section yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Class</TableHead>
              <TableHead>Section</TableHead>
              <TableHead className="text-right">Boys</TableHead>
              <TableHead className="text-right">Girls</TableHead>
              <TableHead className="text-right">Total</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={`${r.cls}|${r.section}`} data-testid="strength-row">
                <TableCell className="font-medium">{r.cls}</TableCell>
                <TableCell>{r.section}</TableCell>
                <TableCell className="tabular text-right">{r.boys}</TableCell>
                <TableCell className="tabular text-right">{r.girls}</TableCell>
                <TableCell className="tabular text-right font-medium">{r.boys + r.girls}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow data-testid="strength-total">
              <TableCell colSpan={2}>Total</TableCell>
              <TableCell className="tabular text-right">{boys}</TableCell>
              <TableCell className="tabular text-right">{girls}</TableCell>
              <TableCell className="tabular text-right">{boys + girls}</TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      )}
    </div>
  );
}
