import Link from 'next/link';
import { notFound } from 'next/navigation';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor, one } from '@/lib/hr/current-role';
import { formatDatePk } from '@/lib/dates';
import { Stat } from '@/components/ui/page-header';
import { PrintButton } from '@/components/print-button';
import { CLASS_TEST_ROLES } from '../schemas';
import { MarksGrid, type MarkRow } from './marks-grid';

export const dynamic = 'force-dynamic';

export default async function ClassTestPage({ params }: { params: Promise<{ testId: string }> }) {
  const actor = await getCurrentActor();
  if (!actor || !CLASS_TEST_ROLES.includes(actor.role)) notFound();
  const { testId } = await params;
  if (!z.string().uuid().safeParse(testId).success) notFound();
  const supabase = await supabaseServer();
  const { data: test } = await supabase
    .from('class_test')
    .select('id, section_id, title, test_date, total_marks, results_sent_at, subject:subject_id(name_en), section:section_id(name, class_level:class_level_id(name_en))')
    .eq('id', testId)
    .maybeSingle();
  if (!test) notFound();
  const [{ data: enrolments }, { data: marks }] = await Promise.all([
    supabase.from('enrolment').select('roll_no, student:student_id!inner(id, name_en, gr_number)').eq('section_id', test.section_id).eq('status', 'active').is('deleted_at', null),
    supabase.from('class_test_mark').select('student_id, marks, absent').eq('test_id', testId),
  ]);
  const byStudent = new Map((marks ?? []).map((m) => [m.student_id, m]));
  const rows: MarkRow[] = (enrolments ?? [])
    .map((e) => one(e.student)!)
    .sort((a, b) => a.name_en.localeCompare(b.name_en))
    .map((s) => ({ studentId: s.id, name: s.name_en, gr: s.gr_number, marks: byStudent.get(s.id)?.marks ?? null, absent: byStudent.get(s.id)?.absent ?? false }));
  const total = Number(test.total_marks);
  const scored = (marks ?? []).filter((m) => !m.absent && m.marks !== null).map((m) => Number(m.marks));
  const avg = scored.length ? scored.reduce((a, b) => a + b, 0) / scored.length : null;
  const sec = one(test.section);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">{test.title}</h1>
          <p className="text-sm text-muted-foreground">
            {`${one(sec?.class_level)?.name_en ?? ''} ${sec?.name ?? ''}`.trim()}
            {one(test.subject) ? ` · ${one(test.subject)!.name_en}` : ''} · {formatDatePk(test.test_date)} · out of {total}
          </p>
        </div>
        <div className="flex gap-2 print:hidden">
          <Link href="/exams/class-tests" className="h-9 px-2 text-sm leading-9 text-muted-foreground underline">
            All tests
          </Link>
          <PrintButton />
        </div>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-4">
        <Stat label="Marked" value={`${(marks ?? []).length} of ${rows.length}`} />
        <Stat label="Average" value={avg === null ? '—' : avg.toFixed(1)} />
        <Stat label="Highest" value={scored.length ? Math.max(...scored) : '—'} />
        <Stat label="Lowest" value={scored.length ? Math.min(...scored) : '—'} />
      </section>
      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No students are enrolled in this section.</p>
      ) : (
        <MarksGrid testId={test.id} total={total} rows={rows} resultsSent={Boolean(test.results_sent_at)} />
      )}
    </div>
  );
}
