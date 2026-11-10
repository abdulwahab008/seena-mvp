import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { allRows } from '@/lib/supabase/all-rows';
import { one } from '@/lib/hr/current-role';
import { PrintButton } from '@/components/print-button';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

type Fail = { subject: string; obtained: number; max: number };
type StudentFails = { id: string; name: string; gr: string; cls: string; sort: number; fails: Fail[] };

export default async function ExamFailuresPage({ searchParams }: { searchParams: Promise<{ term?: string }> }) {
  const { term: termParam } = await searchParams;
  const supabase = await supabaseServer();
  const { data: terms } = await supabase.from('exam_term').select('id, name, sequence, session_id').order('sequence', { ascending: false });
  const term = (terms ?? []).find((t) => t.id === termParam) ?? (terms ?? [])[0];

  const { data: results } = term
    ? await allRows((from, to) =>
        supabase
          .from('subject_result')
          .select('id, enrolment_id, is_pass, obtained, max_marks, subject:subject_id(name_en), enrolment:enrolment_id(student:student_id(id, name_en, gr_number)), section:section_id(name, class_level:class_level_id(name_en, ordinal))')
          .eq('exam_term_id', term.id)
          .order('id')
          .range(from, to),
      )
    : { data: [] };

  const students = new Map<string, StudentFails & { total: number }>();
  for (const r of results) {
    const s = one(one(r.enrolment)?.student);
    const sec = one(r.section);
    if (!s) continue;
    const entry = students.get(r.enrolment_id) ?? { id: s.id, name: s.name_en, gr: s.gr_number, cls: `${one(sec?.class_level)?.name_en ?? ''} ${sec?.name ?? ''}`.trim(), sort: one(sec?.class_level)?.ordinal ?? 0, fails: [], total: 0 };
    entry.total++;
    if (r.is_pass === false) entry.fails.push({ subject: one(r.subject)?.name_en ?? '', obtained: Number(r.obtained), max: Number(r.max_marks) });
    students.set(r.enrolment_id, entry);
  }
  const all = [...students.values()];
  const failing = all.filter((s) => s.fails.length > 0).sort((a, b) => a.sort - b.sort || a.cls.localeCompare(b.cls) || b.fails.length - a.fails.length);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Failure list</h1>
          <p className="text-sm text-muted-foreground">Students who failed one or more subjects in an exam, with the subjects and marks.</p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/exams/results" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            Merit list
          </Link>
          <PrintButton />
        </div>
      </div>
      <form method="get" className="flex items-end gap-2 text-sm print:hidden">
        <select name="term" defaultValue={term?.id ?? ''} aria-label="Exam" className="h-9 min-w-56 rounded-md border bg-background px-2">
          {(terms ?? []).map((t) => (
            <option key={t.id} value={t.id}>
              {t.name}
            </option>
          ))}
        </select>
        <Button type="submit" size="sm" variant="outline">
          Show
        </Button>
      </form>
      {!term ? (
        <p className="text-sm text-muted-foreground">No exams have been set up yet.</p>
      ) : (
        <>
          <section aria-label="Summary" className="grid gap-3 sm:grid-cols-3">
            <Stat label="Students with results" value={all.length} />
            <Stat label="Failed one or more subjects" value={failing.length} tone={failing.length > 0 ? 'destructive' : 'success'} />
            <Stat label="Pass rate" value={all.length ? `${Math.round(((all.length - failing.length) / all.length) * 100)}%` : '—'} />
          </section>
          {failing.length === 0 ? (
            <p className="text-sm text-muted-foreground">{all.length === 0 ? 'No results have been computed for this exam yet.' : 'Nobody failed a subject in this exam.'}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="w-10">#</TableHead>
                  <TableHead>GR no.</TableHead>
                  <TableHead>Student</TableHead>
                  <TableHead>Class</TableHead>
                  <TableHead>Failed subjects</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {failing.map((s, i) => (
                  <TableRow key={s.id} data-testid="failure-row">
                    <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                    <TableCell className="tabular font-mono">{s.gr}</TableCell>
                    <TableCell>
                      <Link href={`/students/${s.id}`} className="font-medium hover:underline">
                        {s.name}
                      </Link>
                    </TableCell>
                    <TableCell>{s.cls}</TableCell>
                    <TableCell>
                      <div className="flex flex-wrap gap-1">
                        {s.fails.map((f) => (
                          <Badge key={f.subject} variant="destructive">
                            {f.subject} {f.obtained}/{f.max}
                          </Badge>
                        ))}
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </>
      )}
    </div>
  );
}
