import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { sessionStatusText, type TranscriptSnapshot } from '@/lib/transcripts/html';
import { IssueForm } from './issue-form';

/**
 * FR-J13. Find a student, review the cumulative history the transcript will
 * carry, and issue it. The history is read through fn_student_transcript, which
 * crosses campuses (a student who moved from one campus to another has one
 * transcript) after checking the caller works where the student is, or was.
 */
type SearchParams = { q?: string; student?: string };

export default async function TranscriptsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();
  const q = (params.q ?? '').trim();

  const { data: matches } = q
    ? await supabase
        .from('student')
        .select('id, name_en, gr_number')
        .or(`name_en.ilike.%${q.replace(/[%,()]/g, ' ')}%,gr_number.ilike.%${q.replace(/[%,()]/g, ' ')}%`)
        .is('deleted_at', null)
        .order('name_en')
        .limit(15)
    : { data: [] };

  const studentId = params.student;
  const [{ data: transcript, error }, { data: issued }] = studentId
    ? await Promise.all([
        supabase.rpc('fn_student_transcript', { p_student_id: studentId }),
        supabase
          .from('transcript_issue')
          .select('id, serial_no, purpose, issued_by_name, issued_on, status')
          .eq('student_id', studentId)
          .order('issued_at', { ascending: false }),
      ])
    : [{ data: null, error: null }, { data: [] }];
  const t = transcript as unknown as TranscriptSnapshot | null;

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Academic transcripts</h1>
        <p className="text-sm text-muted-foreground">
          FR-J13 — every session a student attended, across campuses, in order. A year the student left is marked
          incomplete; a withheld result is marked withheld and shows no marks. Issuing allocates a serial number and
          freezes the document.
        </p>
      </div>

      <form method="get" className="flex items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Student name or GR number</span>
          <input name="q" defaultValue={q} className="h-9 rounded-md border bg-background px-2" data-testid="transcript-search" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3" data-testid="transcript-search-go">
          Search
        </button>
      </form>

      {q && (
        <ul className="space-y-1 text-sm" data-testid="transcript-matches">
          {(matches ?? []).length === 0 && <li className="text-muted-foreground">No student matches.</li>}
          {(matches ?? []).map((m) => (
            <li key={m.id}>
              <Link href={`/transcripts?q=${encodeURIComponent(q)}&student=${m.id}`} className="underline" data-testid={`transcript-pick-${m.gr_number}`}>
                {m.name_en}
              </Link>{' '}
              <span className="text-muted-foreground">{m.gr_number}</span>
            </li>
          ))}
        </ul>
      )}

      {studentId && error && (
        <p className="text-sm text-destructive" role="alert" data-testid="transcript-error">
          You cannot view this student&rsquo;s transcript.
        </p>
      )}

      {t && (
        <section className="space-y-4" data-testid="transcript-preview">
          <h2 className="text-lg font-semibold">
            {t.student.name_en} <span className="text-sm font-normal text-muted-foreground">{t.student.gr_number}</span>
          </h2>
          {t.sessions.length === 0 ? (
            <p className="text-sm text-muted-foreground">No enrolment on record.</p>
          ) : (
            <table className="w-full text-sm">
              <thead className="text-left text-muted-foreground">
                <tr>
                  <th className="py-1">Session</th>
                  <th className="py-1">Class</th>
                  <th className="py-1">Campus</th>
                  <th className="py-1">Terms completed</th>
                  <th className="py-1">Standing</th>
                </tr>
              </thead>
              <tbody>
                {t.sessions.map((s) => (
                  <tr key={s.session_id + s.class_name} className="border-t" data-testid={`transcript-session-${s.session_name}`}>
                    <td className="py-1 font-medium">{s.session_name}</td>
                    <td className="py-1">
                      {s.class_name} {s.section_name}
                    </td>
                    <td className="py-1">{s.campus_name}</td>
                    <td className="py-1">{s.status === 'withheld' ? '—' : s.terms_completed.join(', ') || '—'}</td>
                    <td className="py-1" data-testid={`transcript-standing-${s.session_name}`}>
                      {sessionStatusText(s)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
          <IssueForm studentId={studentId!} />

          {(issued ?? []).length > 0 && (
            <div className="space-y-1" data-testid="transcript-register">
              <h3 className="text-sm font-semibold">Issued</h3>
              <ul className="space-y-1 text-sm">
                {(issued ?? []).map((i) => (
                  <li key={i.id}>
                    <span className="font-mono">{i.serial_no}</span> · {i.purpose} · {i.issued_on} · {i.issued_by_name}
                    {i.status === 'issued' ? (
                      <>
                        {' '}
                        <a href={`/api/transcripts/${i.id}/download`} className="underline">
                          Download
                        </a>
                      </>
                    ) : (
                      <span className="text-muted-foreground"> · {i.status}</span>
                    )}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </section>
      )}
    </div>
  );
}
