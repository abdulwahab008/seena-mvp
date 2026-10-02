import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { groupTrend } from '@/lib/exams/trend';
import { SubjectTrendChart } from '@/components/subject-trend-chart';

/**
 * FR-J06. A child's subject performance across terms against the section
 * average.
 *
 * Reads v_student_subject_trend, whose rows follow subject_result's RLS: a
 * parent gets their own child's points and the aggregate section average, and
 * nothing that identifies another student. The averages were materialised when
 * the papers were locked, so opening this on results day is an indexed read,
 * not a computation.
 */
type SearchParams = { enrolment?: string };

export default async function PortalTrendPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');

  const children = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return { enrolmentId: e.id, studentName: student.name_en, sectionLabel: `${level?.name_en ?? ''} · ${section.name}` };
    })
    .filter((c): c is { enrolmentId: string; studentName: string; sectionLabel: string } => !!c);

  const child = children.find((c) => c.enrolmentId === params.enrolment) ?? children[0];

  const { data: rows } = child
    ? await supabase
        .from('v_student_subject_trend')
        .select(
          'subject_id, subject_name, exam_term_id, term_name, term_sequence, pct, section_avg_pct, comparison_suppressed, comparison_note',
        )
        .eq('enrolment_id', child.enrolmentId)
    : { data: [] };
  const trends = groupTrend(rows ?? []);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Subject progress</h2>
        <p className="text-sm text-muted-foreground">
          FR-J06 — each subject across the terms so far, beside the section average.{' '}
          <Link href="/portal/results" className="underline">
            Back to results
          </Link>
        </p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground">No enrolled child found on this account.</p>
      ) : (
        <>
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="trend-child-selector">
              {children.map((c) => (
                <Link
                  key={c.enrolmentId}
                  href={`/portal/results/trend?enrolment=${c.enrolmentId}`}
                  className={`rounded-full border px-3 py-1 text-sm ${
                    c.enrolmentId === child?.enrolmentId ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                  }`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {trends.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="trend-empty">
              No term results have been published for {child?.studentName} yet.
            </p>
          ) : (
            <div className="space-y-8" data-testid="trend-list">
              {trends.map((t) => (
                <SubjectTrendChart key={t.subjectId} trend={t} />
              ))}
            </div>
          )}
        </>
      )}
    </div>
  );
}
