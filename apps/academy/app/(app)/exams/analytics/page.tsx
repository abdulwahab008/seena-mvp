import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { groupTrend } from '@/lib/exams/trend';
import { SubjectTrendChart } from '@/components/subject-trend-chart';

/**
 * FR-J06 for staff. A section's average per subject and term, and any one
 * student's trend against it.
 *
 * Everything is read from v_section_subject_average / v_student_subject_trend,
 * which sit on the averages materialised when each paper was locked; this
 * page computes nothing. Below five ranked candidates the average is not
 * shown and the page says why.
 */
type SearchParams = { section?: string; student?: string };

export default async function SubjectAnalyticsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase
    .from('campus')
    .select('id, name')
    .eq('status', 'active')
    .order('code')
    .limit(1);
  const campus = campuses?.[0];
  const { data: sessions } = campus
    ? await supabase
        .from('academic_session')
        .select('id, name')
        .or(`campus_id.eq.${campus.id},campus_id.is.null`)
        .eq('is_current', true)
        .order('starts_on', { ascending: false })
        .limit(1)
    : { data: null };
  const session = sessions?.[0];

  if (!campus || !session) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Subject analytics</h1>
        <p className="text-sm text-muted-foreground">No current academic session found for this campus.</p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);
  const section = sections.find((s) => s.id === params.section) ?? sections[0];

  const [{ data: averages }, { data: students }] = section
    ? await Promise.all([
        supabase
          .from('v_section_subject_average')
          .select('subject_id, subject_name, term_name, term_sequence, avg_pct, n, comparison_note')
          .eq('section_id', section.id)
          .order('term_sequence'),
        supabase
          .from('enrolment')
          .select('id, roll_no, student:student_id(name_en)')
          .eq('section_id', section.id)
          .eq('status', 'active')
          .order('roll_no'),
      ])
    : [{ data: [] }, { data: [] }];

  const studentRows = (students ?? []).map((e) => ({
    id: e.id,
    label: `${e.roll_no ?? '—'}. ${(Array.isArray(e.student) ? e.student[0] : e.student)?.name_en ?? ''}`,
  }));
  const chosen = studentRows.find((s) => s.id === params.student);

  const { data: trendRows } = chosen
    ? await supabase
        .from('v_student_subject_trend')
        .select('subject_id, subject_name, exam_term_id, term_name, term_sequence, pct, section_avg_pct, comparison_suppressed, comparison_note')
        .eq('enrolment_id', chosen.id)
    : { data: [] };
  const trends = groupTrend(trendRows ?? []);

  const bySubject = new Map<string, { name: string; cells: { term: string; seq: number; avg: number | null; n: number; note: string | null }[] }>();
  for (const a of averages ?? []) {
    if (!a.subject_id) continue;
    const entry = bySubject.get(a.subject_id) ?? { name: a.subject_name ?? '', cells: [] };
    entry.cells.push({ term: a.term_name ?? '', seq: a.term_sequence ?? 0, avg: a.avg_pct, n: a.n ?? 0, note: a.comparison_note });
    bySubject.set(a.subject_id, entry);
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Subject analytics</h1>
        <p className="text-sm text-muted-foreground">
          FR-J06 — section averages per subject and term, and one student&rsquo;s trend against them.
        </p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Section</span>
          <select name="section" defaultValue={section?.id} className="h-9 rounded-md border bg-background px-2" data-testid="analytics-section">
            {sections.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Student</span>
          <select name="student" defaultValue={chosen?.id ?? ''} className="h-9 rounded-md border bg-background px-2" data-testid="analytics-student">
            <option value="">Section only</option>
            {studentRows.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3" data-testid="analytics-show">
          Show
        </button>
      </form>

      <section className="space-y-2" data-testid="section-averages">
        <h2 className="text-base font-semibold">Section averages</h2>
        {bySubject.size === 0 ? (
          <p className="text-sm text-muted-foreground">No term results have been locked for this section yet.</p>
        ) : (
          <table className="w-full text-sm">
            <thead className="text-left text-muted-foreground">
              <tr>
                <th className="py-1">Subject</th>
                <th className="py-1">Term</th>
                <th className="py-1">Average</th>
                <th className="py-1">Candidates</th>
              </tr>
            </thead>
            <tbody>
              {[...bySubject.values()]
                .sort((a, b) => a.name.localeCompare(b.name))
                .flatMap((s) =>
                  s.cells
                    .sort((a, b) => a.seq - b.seq)
                    .map((c) => (
                      <tr key={`${s.name}-${c.term}`} className="border-t" data-testid={`avg-${s.name}-${c.term}`}>
                        <td className="py-1 font-medium">{s.name}</td>
                        <td className="py-1">{c.term}</td>
                        <td className="py-1">{c.avg === null ? <span className="text-muted-foreground">{c.note ?? 'too few students to compare'}</span> : `${Number(c.avg).toFixed(2)}%`}</td>
                        <td className="py-1">{c.n}</td>
                      </tr>
                    )),
                )}
            </tbody>
          </table>
        )}
      </section>

      {chosen && (
        <section className="space-y-4" data-testid="student-trends">
          <h2 className="text-base font-semibold">{chosen.label}</h2>
          {trends.length === 0 ? (
            <p className="text-sm text-muted-foreground">No locked term results for this student yet.</p>
          ) : (
            trends.map((t) => <SubjectTrendChart key={t.subjectId} trend={t} ownLabel="Student" />)
          )}
        </section>
      )}
    </div>
  );
}
