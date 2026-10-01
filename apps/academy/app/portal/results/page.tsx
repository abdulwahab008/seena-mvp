import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';

/**
 * FR-J08 AC1's parent-facing half.
 *
 * The page is deliberately thin. Everything a parent may see about a withheld
 * result is one sentence — "Result withheld — please contact the accounts
 * office" — and fn_portal_term_result() is what decides whether that sentence
 * or the marks come back. The amount outstanding, the cut-off and the
 * threshold are NOT on this page and are not in the payload: they are an
 * accounts-office conversation, and a portal that prints a family's arrears
 * publishes them to whoever borrows the phone.
 *
 * The child selector and the enrolment query are /portal/timetable's,
 * unchanged — a parent with two children picks between them the same way on
 * every portal screen.
 */
type SearchParams = { enrolment?: string; term?: string };

type Child = { enrolmentId: string; studentName: string; sectionLabel: string };

type PortalTermResult = {
  /** Which terms this child sat — exam_term has no parent-facing RLS policy
   *  and should not grow one, so the list arrives with the result. */
  terms: { exam_term_id: string; name: string }[];
  exam_term_id: string | null;
  exam_term_name: string | null;
  is_withheld: boolean;
  message: string | null;
  subjects: {
    subject_name: string;
    obtained: number | null;
    max_marks: number | null;
    pct: number | null;
    grade_label: string | null;
    is_pass: boolean | null;
    is_blocked: boolean;
  }[];
};

export default async function PortalResultsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student:student_id(id, name_en), class_section:section_id(name, class_level(name_en))')
    .eq('status', 'active');

  const children: Child[] = (enrolments ?? [])
    .map((e) => {
      const student = Array.isArray(e.student) ? e.student[0] : e.student;
      const section = Array.isArray(e.class_section) ? e.class_section[0] : e.class_section;
      const level = section ? (Array.isArray(section.class_level) ? section.class_level[0] : section.class_level) : null;
      if (!student || !section) return null;
      return {
        enrolmentId: e.id,
        studentName: student.name_en,
        sectionLabel: `${level?.name_en ?? ''} · ${section.name}`,
      };
    })
    .filter((c): c is Child => !!c);

  const child = children.find((c) => c.enrolmentId === params.enrolment) ?? children[0];

  const { data } = child
    ? await supabase.rpc('fn_portal_term_result', {
        p_enrolment_id: child.enrolmentId,
        p_exam_term_id: params.term ?? undefined,
      })
    : { data: null };
  const result = data as unknown as PortalTermResult | null;
  const termRows = result?.terms ?? [];

  const { data: cardRows } = child ? await supabase.rpc('fn_portal_report_cards', { p_enrolment_id: child.enrolmentId }) : { data: null };
  const card = (cardRows ?? []).find((c) => c.exam_term_id === result?.exam_term_id) ?? null;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Results</h2>
        <p className="text-sm text-muted-foreground">
          FR-J08 — your child&apos;s result for the term.{' '}
          <Link href="/portal/results/trend" className="underline" data-testid="results-trend-link">
            See progress across terms
          </Link>{' '}
          ·{' '}
          <Link href="/portal/results/transcripts" className="underline" data-testid="results-transcripts-link">
            Transcripts
          </Link>
        </p>
      </div>

      {children.length === 0 ? (
        <p className="text-sm text-muted-foreground">No enrolled child found on this account.</p>
      ) : (
        <>
          {children.length > 1 && (
            <div className="flex flex-wrap gap-2" data-testid="results-child-selector">
              {children.map((c) => (
                <Link
                  key={c.enrolmentId}
                  href={`/portal/results?enrolment=${c.enrolmentId}`}
                  data-testid={`results-child-${c.studentName}`}
                  className={`rounded-full border px-3 py-1 text-sm ${
                    c.enrolmentId === child?.enrolmentId ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                  }`}
                >
                  {c.studentName} ({c.sectionLabel})
                </Link>
              ))}
            </div>
          )}

          {termRows.length > 1 && child && (
            <div className="flex flex-wrap gap-2" data-testid="results-term-selector">
              {termRows.map((t) => (
                <Link
                  key={t.exam_term_id}
                  href={`/portal/results?enrolment=${child.enrolmentId}&term=${t.exam_term_id}`}
                  className={`rounded-full border px-3 py-1 text-sm ${
                    t.exam_term_id === result?.exam_term_id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'
                  }`}
                >
                  {t.name}
                </Link>
              ))}
            </div>
          )}

          {card && (
            <div className="space-y-2 rounded-md border p-3 text-sm" data-testid="portal-report-card">
              {card.under_review && (
                <p className="rounded bg-amber-50 p-2 font-medium text-amber-900" role="status" data-testid="card-under-review">
                  Result under review — a correction is being made to this term&apos;s marks. The card below is the previous version and a revised card will replace it.
                </p>
              )}
              {card.revised_on && (
                <p className="text-muted-foreground" data-testid="card-revised-on">
                  Revised on {card.revised_on} (revision {card.revision_no}).
                </p>
              )}
              <a className="underline-offset-2 hover:underline" href={`/api/report-cards/${card.report_card_id}/download`} data-testid="card-download">
                Download report card (PDF)
              </a>
            </div>
          )}

          {!result ? (
            <p className="text-sm text-muted-foreground" data-testid="portal-result-empty">
              No results have been published yet.
            </p>
          ) : result.is_withheld ? (
            <p className="rounded-md border border-destructive p-4 text-sm text-destructive" data-testid="portal-result-withheld">
              {result.message}
            </p>
          ) : result.subjects.length === 0 ? (
            <p className="text-sm text-muted-foreground" data-testid="portal-result-empty">
              No results have been published yet for {result.exam_term_name}.
            </p>
          ) : (
            <table className="w-full text-sm" data-testid="portal-result-table">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="py-1">Subject</th>
                  <th className="py-1">Marks</th>
                  <th className="py-1">%</th>
                  <th className="py-1">Grade</th>
                </tr>
              </thead>
              <tbody>
                {result.subjects.map((s) => (
                  <tr key={s.subject_name} data-testid={`portal-result-${s.subject_name}`}>
                    <td className="py-1 font-medium">{s.subject_name}</td>
                    <td className="py-1">
                      {s.obtained ?? '—'} / {s.max_marks ?? '—'}
                    </td>
                    <td className="py-1">{s.pct === null ? '—' : Number(s.pct).toFixed(2)}</td>
                    <td className="py-1">{s.grade_label ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </>
      )}
    </div>
  );
}
