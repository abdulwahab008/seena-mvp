import { supabaseServer } from '@/lib/supabase/server';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { ExternalResultForm } from './external-result-form';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function ExternalResultsPage() {
  const supabase = await supabaseServer();
  const { data: rows } = await supabase
    .from('external_result')
    .select('id, board, exam, exam_year, roll_no, obtained, total, grade, student(name_en, gr_number)')
    .order('exam_year', { ascending: false })
    .order('obtained', { ascending: false })
    .limit(500);
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Board results</h1>
        <p className="text-sm text-muted-foreground">
          Results from the board (BISE, Federal Board, Cambridge and so on) for students who sat external exams. Entering the same student, exam and year again corrects it.
        </p>
      </div>
      <ExternalResultForm defaultYear={new Date().getFullYear()} />
      {(rows ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No board results entered yet.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Student</TableHead>
              <TableHead>Board</TableHead>
              <TableHead>Exam</TableHead>
              <TableHead>Year</TableHead>
              <TableHead>Roll no</TableHead>
              <TableHead className="text-right">Marks</TableHead>
              <TableHead className="text-right">%</TableHead>
              <TableHead>Grade</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(rows ?? []).map((r) => {
              const s = one(r.student);
              return (
                <TableRow key={r.id} data-testid="external-result-row">
                  <TableCell>
                    {s?.name_en} <span className="text-xs text-muted-foreground">{s?.gr_number}</span>
                  </TableCell>
                  <TableCell>{r.board}</TableCell>
                  <TableCell>{r.exam}</TableCell>
                  <TableCell>{r.exam_year}</TableCell>
                  <TableCell>{r.roll_no}</TableCell>
                  <TableCell className="text-right">
                    {Number(r.obtained)}/{r.total}
                  </TableCell>
                  <TableCell className="text-right">{((Number(r.obtained) * 100) / r.total).toFixed(1)}</TableCell>
                  <TableCell>{r.grade ?? ''}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
