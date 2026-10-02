import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { summaryLine, uncapturedMessage, type MasterySheet } from '@/lib/exams/mastery';

/**
 * FR-J07. Which chapters a section, or one student, has not mastered.
 *
 * The section figure is pooled across the section and flags a chapter below
 * 50% as a re-teach candidate; a chapter covered by fewer than 3 questions
 * says so. A paper entered as one total has no breakdown, and the page says
 * that rather than drawing an empty chart. Read from the materialised view;
 * nothing is computed here.
 */
type SearchParams = { section?: string; student?: string };

export default async function MasteryPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
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
        <h1 className="text-2xl font-semibold">Topic mastery</h1>
        <p className="text-sm text-muted-foreground">No current academic session found for this campus.</p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);
  const section = sections.find((s) => s.id === params.section) ?? sections[0];

  const [{ data: chapters }, { data: students }] = section
    ? await Promise.all([
        supabase
          .from('v_section_topic_mastery')
          .select('subject_id, subject_name, topic_tag, pct, students, question_count, reteach, low_confidence')
          .eq('section_id', section.id)
          .order('subject_name')
          .order('pct'),
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
  const { data: sheetData } = chosen ? await supabase.rpc('fn_topic_mastery_sheet', { p_enrolment_id: chosen.id }) : { data: null };
  const sheet = sheetData as unknown as MasterySheet | null;

  const bySubject = new Map<string, NonNullable<typeof chapters>>();
  for (const c of chapters ?? []) {
    const key = c.subject_name ?? '';
    bySubject.set(key, [...(bySubject.get(key) ?? []), c]);
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Topic mastery</h1>
        <p className="text-sm text-muted-foreground">
          FR-J07 — per-chapter mastery from per-question marks. Chapters below 50% for the section are re-teach
          candidates. Marks are captured on the{' '}
          <Link href="/exams/mastery/capture" className="underline">
            per-question marks
          </Link>{' '}
          screen.
        </p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Section</span>
          <select name="section" defaultValue={section?.id} className="h-9 rounded-md border bg-background px-2" data-testid="mastery-section">
            {sections.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Student</span>
          <select name="student" defaultValue={chosen?.id ?? ''} className="h-9 rounded-md border bg-background px-2" data-testid="mastery-student">
            <option value="">Section only</option>
            {studentRows.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3" data-testid="mastery-show">
          Show
        </button>
      </form>

      <section className="space-y-4" data-testid="section-mastery">
        <h2 className="text-base font-semibold">Section</h2>
        {bySubject.size === 0 ? (
          <p className="text-sm text-muted-foreground" data-testid="section-mastery-empty">
            No per-question marks have been captured for this section yet.
          </p>
        ) : (
          [...bySubject.entries()].map(([subject, rows]) => (
            <div key={subject} className="space-y-1">
              <h3 className="text-sm font-medium">{subject}</h3>
              <table className="w-full text-sm">
                <thead className="text-left text-muted-foreground">
                  <tr>
                    <th className="py-1">Chapter</th>
                    <th className="py-1">Section mastery</th>
                    <th className="py-1">Questions</th>
                    <th className="py-1" />
                  </tr>
                </thead>
                <tbody>
                  {rows.map((r) => (
                    <tr
                      key={r.topic_tag}
                      className={`border-t ${r.reteach ? 'bg-destructive/5' : ''}`}
                      data-testid={`chapter-${subject}-${r.topic_tag}`}
                      data-reteach={r.reteach ? 'true' : 'false'}
                    >
                      <td className="py-1 font-medium">{r.topic_tag}</td>
                      <td className="py-1">{r.pct === null ? '—' : `${Math.round(Number(r.pct))}%`}</td>
                      <td className="py-1">{r.question_count}</td>
                      <td className="py-1 text-xs">
                        {r.reteach && <span className="text-destructive" data-testid={`reteach-${r.topic_tag}`}>Re-teach</span>}
                        {r.low_confidence && (
                          <span className="ml-2 text-muted-foreground" data-testid={`lowconf-${r.topic_tag}`}>
                            low confidence — fewer than 3 questions
                          </span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))
        )}
      </section>

      {chosen && sheet && (
        <section className="space-y-3" data-testid="student-mastery">
          <h2 className="text-base font-semibold">{sheet.student_name}</h2>
          {sheet.has_breakdown && (
            <p className="text-sm" data-testid="student-summary">
              {summaryLine(sheet.topics)}
            </p>
          )}
          {sheet.topics.length > 0 && (
            <ul className="space-y-1 text-sm">
              {sheet.topics.map((t) => (
                <li key={`${t.subject_name}-${t.topic_tag}`} data-testid={`student-chapter-${t.topic_tag}`}>
                  {t.subject_name} · {t.topic_tag} · {t.pct === null ? '—' : `${Math.round(Number(t.pct))}%`} ({Number(t.obtained)} of {Number(t.max_marks)})
                  {t.low_confidence && <span className="ml-2 text-xs text-muted-foreground">low confidence</span>}
                </li>
              ))}
            </ul>
          )}
          {sheet.uncaptured.map((u) => (
            <p key={u.exam_subject_id} className="text-sm text-muted-foreground" data-testid="uncaptured-note">
              {uncapturedMessage(u)}
            </p>
          ))}
        </section>
      )}
    </div>
  );
}
