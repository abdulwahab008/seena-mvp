import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { todayPk } from '@/lib/dates';
import { PrintButton } from '@/components/print-button';
import { Badge } from '@/components/ui/badge';
import { Stat } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

export default async function CurriculumReportsPage() {
  const today = todayPk();
  const supabase = await supabaseServer();
  const [{ data: sections }, { data: classSubjects }, { data: allocations }, { data: questions }, { data: units }, { data: topics }, { data: coverage }] = await Promise.all([
    supabase.from('class_section').select('id, name, session_id, class_level:class_level_id(id, name_en, ordinal)').eq('is_active', true),
    supabase.from('class_subject').select('class_level_id, session_id, subject:subject_id(id, name_en)'),
    supabase
      .from('section_subject_teacher')
      .select('section_id, subject_id, staff:staff_id(full_name)')
      .not('staff_id', 'is', null)
      .lte('effective_from', today)
      .or(`effective_to.is.null,effective_to.gte.${today}`),
    supabase.from('question_bank_item').select('difficulty, class_level_id, subject_id, subject:subject_id(name_en)').eq('is_active', true),
    supabase.from('syllabus_unit').select('id, class_level_id, subject_id, session_id, target_month'),
    supabase.from('syllabus_topic').select('syllabus_unit_id'),
    supabase.from('syllabus_coverage').select('syllabus_unit_id, section_id, status, completed_on'),
  ]);

  const rows = (sections ?? []).flatMap((sec) => {
    const cl = one(sec.class_level);
    if (!cl) return [];
    return (classSubjects ?? [])
      .filter((cs) => cs.class_level_id === cl.id && cs.session_id === sec.session_id)
      .flatMap((cs) => {
        const subject = one(cs.subject);
        if (!subject) return [];
        const teachers = (allocations ?? []).filter((a) => a.section_id === sec.id && a.subject_id === subject.id).map((a) => one(a.staff)?.full_name).filter((n): n is string => Boolean(n));
        return [{ key: `${sec.id}-${subject.id}`, cls: `${cl.name_en} ${sec.name}`, sort: cl.ordinal, subject: subject.name_en, teachers }];
      });
  }).sort((a, b) => a.sort - b.sort || a.cls.localeCompare(b.cls) || a.subject.localeCompare(b.subject));
  const missing = rows.filter((r) => r.teachers.length === 0);

  const difficulties = [...new Set((questions ?? []).map((q) => q.difficulty))].sort();
  const bank = new Map<string, Map<string, number>>();
  for (const q of questions ?? []) {
    const s = one(q.subject)?.name_en ?? 'No subject';
    const m = bank.get(s) ?? new Map<string, number>();
    m.set(q.difficulty, (m.get(q.difficulty) ?? 0) + 1);
    bank.set(s, m);
  }
  const bankRows = [...bank.entries()].sort((a, b) => a[0].localeCompare(b[0]));

  // Per class and subject: chapters planned, how many section-chapters are done, done on time
  // (by the end of the chapter's target month), and missed (target month over, not done).
  const monthEnd = (m: string) => new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).toISOString().slice(0, 10);
  const subjectsByClass = new Map<string, { cls: string; sort: number; subjectId: string; subject: string; classId: string; sessionId: string; sections: string[]; teachers: number }>();
  for (const sec of sections ?? []) {
    const cl = one(sec.class_level);
    if (!cl) continue;
    for (const cs of classSubjects ?? []) {
      const subject = one(cs.subject);
      if (!subject || cs.class_level_id !== cl.id || cs.session_id !== sec.session_id) continue;
      const key = `${cl.id}-${subject.id}`;
      const e = subjectsByClass.get(key) ?? { cls: cl.name_en, sort: cl.ordinal, subjectId: subject.id, subject: subject.name_en, classId: cl.id, sessionId: sec.session_id, sections: [], teachers: 0 };
      e.sections.push(sec.id);
      e.teachers += (allocations ?? []).filter((a) => a.section_id === sec.id && a.subject_id === subject.id).length;
      subjectsByClass.set(key, e);
    }
  }
  const coverageRows = [...subjectsByClass.entries()]
    .map(([key, c]) => {
      const myUnits = (units ?? []).filter((u) => u.class_level_id === c.classId && u.subject_id === c.subjectId && u.session_id === c.sessionId);
      const unitIds = new Set(myUnits.map((u) => u.id));
      const done = (coverage ?? []).filter((x) => unitIds.has(x.syllabus_unit_id) && c.sections.includes(x.section_id) && x.status === 'completed');
      const target = new Map(myUnits.map((u) => [u.id, u.target_month]));
      const onTime = done.filter((x) => {
        const t = target.get(x.syllabus_unit_id);
        return t && x.completed_on && x.completed_on <= monthEnd(t);
      }).length;
      const planned = myUnits.length * c.sections.length;
      const missed = myUnits.filter((u) => u.target_month && monthEnd(u.target_month) < today).reduce(
        (t, u) => t + c.sections.filter((sid) => !done.some((x) => x.syllabus_unit_id === u.id && x.section_id === sid)).length,
        0,
      );
      return {
        key, cls: c.cls, sort: c.sort, subject: c.subject, chapters: myUnits.length, planned, done: done.length, onTime, missed,
        topics: (topics ?? []).filter((t) => unitIds.has(t.syllabus_unit_id)).length,
        teacher: c.teachers > 0,
        questions: (questions ?? []).filter((q) => q.class_level_id === c.classId && q.subject_id === c.subjectId).length,
      };
    })
    .sort((a, b) => a.sort - b.sort || a.subject.localeCompare(b.subject));
  const pct = (n: number, d: number) => (d ? `${Math.round((n / d) * 100)}%` : '—');

  return (
    <div className="space-y-8">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Curriculum reports</h1>
          <p className="text-sm text-muted-foreground">Who teaches each subject in each class, and how many questions the question bank holds.</p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/syllabus-coverage" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            Syllabus coverage
          </Link>
          <PrintButton />
        </div>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-3">
        <Stat label="Class subjects" value={rows.length} />
        <Stat label="Without a teacher" value={missing.length} tone={missing.length > 0 ? 'destructive' : 'success'} />
        <Stat label="Questions in the bank" value={(questions ?? []).length} />
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Teacher assignment</h2>
        {rows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No subjects are set up for the classes yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Class</TableHead>
                <TableHead>Subject</TableHead>
                <TableHead>Teacher</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.key} data-testid="assignment-row">
                  <TableCell className="font-medium">{r.cls}</TableCell>
                  <TableCell>{r.subject}</TableCell>
                  <TableCell>{r.teachers.length ? r.teachers.join(', ') : <Badge variant="destructive">No teacher</Badge>}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Lesson coverage</h2>
        <p className="text-sm text-muted-foreground">Chapters completed across all sections, on time against each chapter&apos;s target month, and chapters whose month has passed unfinished.</p>
        {coverageRows.length === 0 ? (
          <p className="text-sm text-muted-foreground">No subjects are set up for the classes yet.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Class</TableHead>
                <TableHead>Subject</TableHead>
                <TableHead className="text-right">Chapters</TableHead>
                <TableHead className="text-right">Completed</TableHead>
                <TableHead className="text-right">On time</TableHead>
                <TableHead className="text-right">Missed</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {coverageRows.map((r) => (
                <TableRow key={r.key} data-testid="coverage-row">
                  <TableCell className="font-medium">{r.cls}</TableCell>
                  <TableCell>{r.subject}</TableCell>
                  <TableCell className="tabular text-right">{r.chapters}</TableCell>
                  <TableCell className="tabular text-right">{pct(r.done, r.planned)}</TableCell>
                  <TableCell className="tabular text-right">{pct(r.onTime, r.done)}</TableCell>
                  <TableCell className={`tabular text-right ${r.missed > 0 ? 'font-medium text-destructive' : ''}`}>{r.missed}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Curriculum completeness</h2>
        <p className="text-sm text-muted-foreground">Whether each subject has its chapters, topics, a teacher and questions set up.</p>
        {coverageRows.length > 0 && (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Class</TableHead>
                <TableHead>Subject</TableHead>
                <TableHead className="text-right">Chapters</TableHead>
                <TableHead className="text-right">Topics</TableHead>
                <TableHead>Teacher</TableHead>
                <TableHead className="text-right">Questions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {coverageRows.map((r) => (
                <TableRow key={r.key} data-testid="completeness-row">
                  <TableCell className="font-medium">{r.cls}</TableCell>
                  <TableCell>{r.subject}</TableCell>
                  {[r.chapters, r.topics].map((n, i) => (
                    <TableCell key={i} className={`tabular text-right ${n === 0 ? 'text-destructive' : ''}`}>
                      {n}
                    </TableCell>
                  ))}
                  <TableCell>{r.teacher ? 'Yes' : <span className="text-destructive">No</span>}</TableCell>
                  <TableCell className={`tabular text-right ${r.questions === 0 ? 'text-destructive' : ''}`}>{r.questions}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>

      <section className="space-y-2">
        <h2 className="text-lg font-semibold">Question bank by subject</h2>
        {bankRows.length === 0 ? (
          <p className="text-sm text-muted-foreground">The question bank is empty.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Subject</TableHead>
                {difficulties.map((d) => (
                  <TableHead key={d} className="text-right capitalize">
                    {d}
                  </TableHead>
                ))}
                <TableHead className="text-right">Total</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {bankRows.map(([subject, counts]) => (
                <TableRow key={subject} data-testid="bank-row">
                  <TableCell className="font-medium">{subject}</TableCell>
                  {difficulties.map((d) => (
                    <TableCell key={d} className="tabular text-right">
                      {counts.get(d) ?? 0}
                    </TableCell>
                  ))}
                  <TableCell className="tabular text-right font-medium">{[...counts.values()].reduce((t, n) => t + n, 0)}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </section>
    </div>
  );
}
