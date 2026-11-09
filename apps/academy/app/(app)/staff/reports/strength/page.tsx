import { supabaseServer } from '@/lib/supabase/server';
import { PrintButton } from '@/components/print-button';
import { Table, TableBody, TableCell, TableFooter, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
type Row = { department: string; designation: string; male: number; female: number };

export default async function StaffStrengthPage() {
  const supabase = await supabaseServer();
  const { data, error } = await supabase
    .from('staff')
    .select('gender, department:department_id(name_en), designation:designation_id(name_en)')
    .eq('employment_status', 'active');

  const counts = new Map<string, Row>();
  for (const s of data ?? []) {
    const department = one(s.department)?.name_en ?? 'No department';
    const designation = one(s.designation)?.name_en ?? 'No designation';
    const key = `${department}|${designation}`;
    const row = counts.get(key) ?? { department, designation, male: 0, female: 0 };
    if (s.gender === 'male') row.male++;
    else row.female++;
    counts.set(key, row);
  }
  const rows = [...counts.values()].sort((a, b) => a.department.localeCompare(b.department) || a.designation.localeCompare(b.designation));
  const male = rows.reduce((t, r) => t + r.male, 0);
  const female = rows.reduce((t, r) => t + r.female, 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Staff strength report</h1>
          <p className="text-sm text-muted-foreground">Active staff by department and designation, men and women.</p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      {error ? (
        <p className="text-sm text-destructive">Could not load staff. Try again.</p>
      ) : rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No active staff yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Department</TableHead>
              <TableHead>Designation</TableHead>
              <TableHead className="text-right">Men</TableHead>
              <TableHead className="text-right">Women</TableHead>
              <TableHead className="text-right">Total</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((r) => (
              <TableRow key={`${r.department}|${r.designation}`} data-testid="strength-row">
                <TableCell className="font-medium">{r.department}</TableCell>
                <TableCell>{r.designation}</TableCell>
                <TableCell className="tabular text-right">{r.male}</TableCell>
                <TableCell className="tabular text-right">{r.female}</TableCell>
                <TableCell className="tabular text-right font-medium">{r.male + r.female}</TableCell>
              </TableRow>
            ))}
          </TableBody>
          <TableFooter>
            <TableRow>
              <TableCell colSpan={2}>Total</TableCell>
              <TableCell className="tabular text-right">{male}</TableCell>
              <TableCell className="tabular text-right">{female}</TableCell>
              <TableCell className="tabular text-right">{male + female}</TableCell>
            </TableRow>
          </TableFooter>
        </Table>
      )}
    </div>
  );
}
