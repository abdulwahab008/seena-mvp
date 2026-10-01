import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { getExamOfficeScope } from '@/lib/exams/office-scope';
import { PaperFilesPanel, PublishPaperPanel, ReplaceQuestionForm } from './paper-builder';

/**
 * FR-I05 / FR-I06. One generated paper and its builder: sections and questions
 * with provenance, questions the class has already seen within the cooldown
 * flagged amber ("used 1 term ago") with the total flagged count, and the
 * publish control (an override reason is asked for only when flagged questions
 * remain; in block mode it is required).
 */
type Section = { no: number; name: string; type: string; count: number; marks_each: number };

export default async function PaperDetailPage({ params }: { params: Promise<{ paperId: string }> }) {
  const { paperId } = await params;
  const supabase = await supabaseServer();
  const scope = await getExamOfficeScope(supabase);
  const { data: paper } = await supabase.from('exam_paper').select('id, campus_id, exam_subject_id, set_code, status, title, total_marks, pattern_snapshot, created_at, published_at').eq('id', paperId).maybeSingle();
  if (!paper) notFound();
  const { data: questions } = await supabase
    .from('exam_paper_item')
    .select('id, section_no, question_no, question_type, marks, question_text, options, answer, chapter, topic_tag, slo_code, source_pages')
    .eq('paper_id', paperId)
    .order('section_no')
    .order('question_no');
  const sections = ((paper.pattern_snapshot as { sections?: Section[] } | null)?.sections ?? []) as Section[];

  const { data: flagRows } = paper.status === 'draft' ? await supabase.rpc('fn_question_reuse_check', { p_paper_id: paperId }) : { data: [] };
  const flags = new Map((flagRows ?? []).map((f) => [f.item_id, f]));
  const { data: settings } = await supabase.from('exam_settings').select('cooldown_mode, question_cooldown_terms').eq('campus_id', paper.campus_id).maybeSingle();
  const mode = settings?.cooldown_mode ?? 'warn';

  const { data: siblingRows } = await supabase.from('exam_paper').select('id, set_code, status').eq('exam_subject_id', paper.exam_subject_id).neq('status', 'superseded').order('set_code');
  const siblings = siblingRows ?? [];
  const baseline = siblings.find((s) => s.set_code !== paper.set_code && s.set_code === 'A') ?? siblings.find((s) => s.set_code !== paper.set_code) ?? null;
  const { data: reportRows } = baseline ? await supabase.rpc('fn_paper_set_report', { p_paper_a: baseline.id, p_paper_b: paper.id }) : { data: [] };
  const report = reportRows ?? [];
  const { data: divergence } = baseline ? await supabase.rpc('fn_paper_set_divergence', { p_paper_a: baseline.id, p_paper_b: paper.id }) : { data: null };

  const { data: releaseRows } = paper.status === 'published' ? await supabase.rpc('fn_paper_release_info', { p_paper_id: paperId }) : { data: [] };
  const release = releaseRows?.[0] ?? null;
  const sealed = paper.status === 'published' && !!release && !release.window_open;
  const { data: logRows } = scope.canWrite ? await supabase.rpc('fn_paper_access_log', { p_paper_id: paperId }) : { data: [] };

  const { data: override } = await supabase.from('paper_publish_override').select('reason, flagged_count, created_at, overridden_by').eq('exam_paper_id', paperId).maybeSingle();
  const { data: overrider } = override ? await supabase.from('app_user').select('full_name').eq('user_id', override.overridden_by).maybeSingle() : { data: null };

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <Link className="text-sm underline" href="/exams/papers">
          Back to papers
        </Link>
        <h1 className="text-2xl font-semibold">{paper.title}</h1>
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          Set {paper.set_code} · {paper.total_marks} marks <Badge variant={paper.status === 'published' ? 'success' : 'outline'} data-testid="paper-status">{paper.status}</Badge>
        </p>
      </div>

      {paper.status === 'draft' && (
        <div
          className={flags.size > 0 ? 'rounded-md border border-amber-500 bg-amber-50 p-3 text-sm text-amber-900' : 'rounded-md border p-3 text-sm text-muted-foreground'}
          role="status"
          data-testid="flag-summary"
        >
          {flags.size > 0
            ? `${flags.size} question${flags.size === 1 ? '' : 's'} flagged: this class saw ${flags.size === 1 ? 'it' : 'them'} within the last ${settings?.question_cooldown_terms ?? 4} terms.`
            : 'No question in this draft was used by this class within the cooldown.'}
        </div>
      )}

      {paper.status === 'published' && (
        <div className={sealed || !release?.release_at ? 'rounded-md border border-amber-500 bg-amber-50 p-3 text-sm text-amber-900' : 'rounded-md border p-3 text-sm text-muted-foreground'} role="status" data-testid="seal-status">
          {!release?.release_at
            ? 'Sealed: this paper has no scheduled exam, so it is not released.'
            : sealed
              ? `Sealed until ${new Date(release.release_at).toLocaleString('en-GB', { timeZone: scope.campus?.timezone ?? 'Asia/Karachi', weekday: 'short', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })} (${release.offset_minutes} minutes before the exam). Its questions and files cannot be read before then.`
              : 'Released: the release window is open. Every download is recorded.'}
        </div>
      )}

      {override && (
        <div className="rounded-md border p-3 text-sm" data-testid="override-record">
          Published with an override by {overrider?.full_name ?? 'a controller'} on {new Date(override.created_at).toLocaleDateString('en-GB')}: {override.reason} ({override.flagged_count} flagged question{override.flagged_count === 1 ? '' : 's'}).
        </div>
      )}

      {sections.map((s) => (
        <Card key={s.no}>
          <CardHeader>
            <CardTitle className="text-base">
              {s.name} — {s.count} × {s.marks_each} marks
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm" data-testid={`section-${s.no}`}>
            {(questions ?? [])
              .filter((q) => q.section_no === s.no)
              .map((q) => {
                const options = Array.isArray(q.options) ? (q.options as string[]) : [];
                const pages = Array.isArray(q.source_pages) ? (q.source_pages as number[]) : [];
                const flag = flags.get(q.id);
                return (
                  <div key={q.id} className={`space-y-1 border-b pb-2 ${flag ? 'rounded-md border border-amber-400 bg-amber-50 p-2 text-amber-950' : ''}`} data-testid="paper-question" data-flagged={flag ? 'true' : 'false'}>
                    <p>
                      <span className="font-medium">Q{q.question_no}.</span> {q.question_text} <span className="text-muted-foreground">[{q.marks}]</span>
                    </p>
                    {flag && (
                      <p className="text-xs font-medium" data-testid="reuse-flag">
                        Used {flag.terms_ago} term{flag.terms_ago === 1 ? '' : 's'} ago ({flag.last_used_term})
                      </p>
                    )}
                    {options.length > 0 && (
                      <ul className="list-disc pl-6 text-muted-foreground">
                        {options.map((o, i) => (
                          <li key={i}>{o}</li>
                        ))}
                      </ul>
                    )}
                    <p className="text-xs text-muted-foreground">
                      {[q.chapter, q.topic_tag, q.slo_code, pages.length > 0 ? `pp. ${pages.join(', ')}` : null, q.answer ? `answer: ${q.answer}` : null].filter(Boolean).join(' · ')}
                    </p>
                    {flag && scope.canWrite && paper.status === 'draft' && <ReplaceQuestionForm paperId={paper.id} itemId={q.id} />}
                  </div>
                );
              })}
          </CardContent>
        </Card>
      ))}

      {siblings.length > 1 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Sets of this paper</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm" data-testid="set-compare">
            <p className="flex flex-wrap gap-3">
              {siblings.map((s) => (
                <Link key={s.id} href={`/exams/papers/${s.id}`} className={s.id === paper.id ? 'font-medium underline' : 'underline'} data-testid="set-link">
                  Set {s.set_code} ({s.status})
                </Link>
              ))}
            </p>
            {baseline && report.length > 0 && (
              <>
                <p className="text-muted-foreground" data-testid="set-divergence">
                  Set {paper.set_code} shares {Math.round(Number(divergence ?? 0) * 100)}% of its questions with Set {baseline.set_code}.
                </p>
                <table className="w-full text-xs" data-testid="set-report">
                  <thead className="text-left text-muted-foreground">
                    <tr>
                      <th>Section</th>
                      <th>Chapter</th>
                      <th>Set {baseline.set_code}</th>
                      <th>Set {paper.set_code}</th>
                      <th>Identical</th>
                    </tr>
                  </thead>
                  <tbody>
                    {report.map((r) => (
                      <tr key={`${r.section_no}-${r.chapter}`}>
                        <td>{r.section_no}</td>
                        <td>{r.chapter ?? '—'}</td>
                        <td>{r.count_a}</td>
                        <td>{r.count_b}</td>
                        <td>{r.identical}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            )}
          </CardContent>
        </Card>
      )}

      {scope.canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Files</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm">
            <p className="text-muted-foreground">The paper and its answer key are stored per set ({`set-${paper.set_code}.pdf`}, {`key-${paper.set_code}.pdf`}); the key you download is always this set&rsquo;s own.</p>
            <PaperFilesPanel paperId={paper.id} setCode={paper.set_code} />
          </CardContent>
        </Card>
      )}

      {scope.canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Access log</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2 text-sm" data-testid="access-log">
            <p className="text-muted-foreground">Every attempt to obtain this paper or its key, oldest first. The log is append-only.</p>
            {(logRows ?? []).length === 0 && <p className="text-muted-foreground">No one has asked for this paper yet.</p>}
            {(logRows ?? []).map((l, i) => (
              <p key={i} data-testid="access-row" data-outcome={l.outcome}>
                {new Date(l.accessed_at).toLocaleString('en-GB', { timeZone: scope.campus?.timezone ?? 'Asia/Karachi', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit', second: '2-digit' })} · {l.user_name} ({l.user_role.replace('_', ' ')}) · {l.kind} ·{' '}
                <Badge variant={l.outcome === 'granted' ? 'success' : 'destructive'}>{l.outcome}</Badge> ({l.reason.replace('_', ' ')}){l.ip ? ` · ${l.ip}` : ''}
              </p>
            ))}
          </CardContent>
        </Card>
      )}

      {paper.status === 'draft' && scope.canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Publish</CardTitle>
          </CardHeader>
          <CardContent>
            <PublishPaperPanel paperId={paper.id} flagged={flags.size} mode={mode} />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
