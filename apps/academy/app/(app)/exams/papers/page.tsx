import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { getExamOfficeScope, one } from '@/lib/exams/office-scope';
import { BuildSetsForm, CooldownSettingsForm, JobPoller, PatternForm, RequestForm, RetryButton } from './paper-forms';

/**
 * FR-I05. Ask Seena Exams for a question paper from a board pattern and a list
 * of chapters. The request becomes a job card at once (no blocking spinner); the
 * worker's result arrives asynchronously and is stored only when it matches the
 * pattern exactly. A failed job shows a retry action.
 */
const STATUS_LABEL: Record<string, string> = {
  queued: 'queued',
  running: 'generating',
  completed: 'ready',
  failed: 'failed',
  pattern_mismatch: 'pattern mismatch',
  copyright_blocked: 'copyright blocked',
};
const STATUS_VARIANT: Record<string, 'success' | 'outline' | 'destructive'> = { completed: 'success', failed: 'destructive', pattern_mismatch: 'destructive', copyright_blocked: 'destructive' };

export default async function PapersPage() {
  const supabase = await supabaseServer();
  const scope = await getExamOfficeScope(supabase);

  const { data: patternRows } = await supabase.from('board_pattern_ref').select('id, code, name, board, total_marks, sections').eq('is_active', true).order('code');
  const patterns = (patternRows ?? []).map((p) => ({ id: p.id, label: `${p.code} · ${p.name} (${p.total_marks})`, totalMarks: p.total_marks }));

  const { data: paperRows } = await supabase
    .from('exam_subject')
    .select('id, class_subject:class_subject_id(class_level:class_level_id(name_en, ordinal), subject:subject_id(name_en)), term:exam_term_id(name)')
    .order('created_at');
  const papers = (paperRows ?? [])
    .map((p) => {
      const cs = one(p.class_subject);
      return { id: p.id, ordinal: one(cs?.class_level)?.ordinal ?? 0, label: `${one(cs?.class_level)?.name_en ?? ''} · ${one(cs?.subject)?.name_en ?? ''} (${one(p.term)?.name ?? ''})` };
    })
    .sort((a, b) => a.ordinal - b.ordinal || a.label.localeCompare(b.label));
  const paperLabel = new Map(papers.map((p) => [p.id, p.label]));

  const { data: jobs } = await supabase
    .from('paper_generation_job')
    .select('id, exam_subject_id, status, attempts, max_retries, last_error, chapters, total_marks, set_count, next_attempt_at, created_at, pattern_snapshot')
    .order('created_at', { ascending: false })
    .limit(30);
  const { data: paperList } = await supabase.from('exam_paper').select('id, job_id, set_code, status, title, total_marks, created_at').order('created_at', { ascending: false }).limit(60);
  const papersByJob = new Map<string, { id: string; set_code: string; status: string }[]>();
  for (const p of paperList ?? []) papersByJob.set(p.job_id, [...(papersByJob.get(p.job_id) ?? []), p]);
  const { data: cooldown } = scope.campus ? await supabase.from('exam_settings').select('question_cooldown_terms, cooldown_mode').eq('campus_id', scope.campus.id).maybeSingle() : { data: null };
  const active = (jobs ?? []).some((j) => j.status === 'queued' || j.status === 'running');

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Question papers</h1>
        <p className="text-sm text-muted-foreground">
          FR-I05 — generate a paper from the prescribed textbook and the board pattern. A paper is stored only when its sections, question counts and marks equal the pattern exactly.
        </p>
      </div>
      <JobPoller active={active} />

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Request a paper</CardTitle>
        </CardHeader>
        <CardContent>
          {patterns.length === 0 ? (
            <p className="text-sm text-muted-foreground">No board pattern is defined yet.{scope.canWrite ? ' Add one below.' : ' Ask the exam office to add one.'}</p>
          ) : papers.length === 0 ? (
            <p className="text-sm text-muted-foreground">No exam subjects are set up yet.</p>
          ) : (
            <RequestForm papers={papers.map((p) => ({ id: p.id, label: p.label }))} patterns={patterns} />
          )}
        </CardContent>
      </Card>

      {patterns.length > 0 && papers.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Set A / Set B from the question bank</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p className="text-muted-foreground">
              Builds blueprint-identical sets (same marks per section, same questions per chapter) from questions this class has not seen recently. Set B shares at most the number you allow with Set A; if the bank cannot supply that, nothing is built.
            </p>
            <BuildSetsForm papers={papers.map((p) => ({ id: p.id, label: p.label }))} patterns={patterns} />
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Jobs</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="job-list">
          {(jobs ?? []).length === 0 && <p className="text-muted-foreground">No paper has been requested yet.</p>}
          {(jobs ?? []).map((j) => {
            const made = papersByJob.get(j.id) ?? [];
            const pattern = j.pattern_snapshot as { code?: string } | null;
            return (
              <div key={j.id} className="space-y-1 border-b pb-3" data-testid="job-card" data-status={j.status}>
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <span className="font-medium">{paperLabel.get(j.exam_subject_id) ?? 'Paper'}</span>
                  <span className="flex items-center gap-2">
                    <Badge variant={STATUS_VARIANT[j.status] ?? 'outline'} data-testid="job-status">
                      {STATUS_LABEL[j.status] ?? j.status}
                    </Badge>
                    {j.status === 'failed' && <RetryButton jobId={j.id} />}
                  </span>
                </div>
                <p className="text-xs text-muted-foreground">
                  {pattern?.code ?? 'pattern'} · {j.total_marks} marks · {j.set_count} set{j.set_count === 1 ? '' : 's'} · {j.chapters.join(', ')}
                </p>
                {j.status === 'queued' && j.attempts > 0 && (
                  <p className="text-xs text-muted-foreground">
                    Attempt {j.attempts} of {j.max_retries + 1} did not go through; retrying at {new Date(j.next_attempt_at).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}.
                  </p>
                )}
                {j.last_error && j.status !== 'completed' && (
                  <p className="text-xs text-destructive" data-testid="job-error">
                    {j.last_error}
                  </p>
                )}
                {made.length > 0 && (
                  <p className="flex flex-wrap gap-3">
                    {made
                      .sort((a, b) => a.set_code.localeCompare(b.set_code))
                      .map((p) => (
                        <Link key={p.id} className="underline" href={`/exams/papers/${p.id}`} data-testid="paper-link">
                          Open set {p.set_code} ({p.status})
                        </Link>
                      ))}
                  </p>
                )}
              </div>
            );
          })}
        </CardContent>
      </Card>

      {scope.canWrite && scope.campus && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Question reuse cooldown</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            <p className="text-muted-foreground">
              A question a class has already seen within this many terms is flagged amber in the paper builder. By default a flagged paper can still be published; choose &ldquo;block&rdquo; to require an override reason.
            </p>
            <CooldownSettingsForm campusId={scope.campus.id} terms={cooldown?.question_cooldown_terms ?? 4} mode={(cooldown?.cooldown_mode as 'warn' | 'block' | undefined) ?? 'warn'} />
          </CardContent>
        </Card>
      )}

      {scope.canWrite && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Board patterns</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4 text-sm">
            <ul className="space-y-1" data-testid="pattern-list">
              {(patternRows ?? []).length === 0 && <li className="text-muted-foreground">No patterns yet.</li>}
              {(patternRows ?? []).map((p) => (
                <li key={p.id}>
                  {p.code} · {p.name} — {p.board} — {p.total_marks} marks (
                  {(p.sections as unknown as { count: number; marks_each: number; type: string }[]).map((s) => `${s.count} ${s.type} × ${s.marks_each}`).join(', ')})
                </li>
              ))}
            </ul>
            <PatternForm />
          </CardContent>
        </Card>
      )}
    </div>
  );
}
