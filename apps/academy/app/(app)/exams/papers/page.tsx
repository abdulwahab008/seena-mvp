import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PaperForm, type ScopeUnit } from './paper-form';

type SearchParams = { class?: string; subject?: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function PapersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const [{ data: classes }, { data: subjects }] = await Promise.all([
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('subject').select('id, name_en').eq('is_active', true).order('name_en'),
  ]);
  const classId = classes?.find((c) => c.id === sp.class)?.id ?? classes?.[0]?.id;
  const subjectId = subjects?.find((s) => s.id === sp.subject)?.id ?? subjects?.[0]?.id;

  let units: ScopeUnit[] = [];
  let sections: { id: string; label: string }[] = [];
  if (classId && subjectId) {
    const [{ data: unitRows }, { data: cov }, { data: secRows }] = await Promise.all([
      supabase.from('syllabus_unit').select('id, sequence, title, board').eq('class_level_id', classId).eq('subject_id', subjectId).order('board').order('sequence'),
      supabase.from('syllabus_coverage').select('syllabus_unit_id, status').eq('subject_id', subjectId).in('status', ['in_progress', 'completed']),
      supabase.from('class_section').select('id, name').eq('class_level_id', classId).eq('is_active', true).order('name'),
    ]);
    const started = new Set((cov ?? []).map((c) => c.syllabus_unit_id));
    const board = unitRows?.[0]?.board;
    units = (unitRows ?? []).filter((u) => u.board === board).map((u) => ({ id: u.id, sequence: u.sequence, title: u.title, taught: started.has(u.id) }));
    sections = (secRows ?? []).map((s) => ({ id: s.id, label: `Section ${s.name}` }));
  }

  const { data: requests } = await supabase
    .from('exam_paper_request')
    .select('id, title, status, untaught_override, created_at, scope_unit_ids, subject:subject_id(name_en), class_level:class_level_id(name_en)')
    .order('created_at', { ascending: false })
    .limit(30);

  const select = (name: string, value: string | undefined, options: { id: string; label: string }[]) => (
    <label className="space-y-1">
      <span className="block text-muted-foreground">{name}</span>
      <select name={name.toLowerCase()} defaultValue={value} className="h-9 rounded-md border bg-background px-2">
        {options.map((o) => (
          <option key={o.id} value={o.id}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );
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
        <h1 className="text-2xl font-semibold">Exam paper scope</h1>
        <p className="text-sm text-muted-foreground">
          FR-H09 — choose the syllabus chapters a generated paper may draw questions from. Chapters whose coverage is still not started are refused unless an Exam Controller explicitly includes them.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">New paper</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
            {select('Class', classId, (classes ?? []).map((c) => ({ id: c.id, label: c.name_en })))}
            {select('Subject', subjectId, (subjects ?? []).map((s) => ({ id: s.id, label: s.name_en })))}
            <button type="submit" className="h-9 rounded-md border px-3">
              Show chapters
            </button>
          </form>
          <PaperForm key={`${classId}-${subjectId}`} units={units} sections={sections} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Requested papers</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="paper-list">
          {(requests ?? []).length === 0 && <p className="text-muted-foreground">No papers requested yet.</p>}
          {(requests ?? []).map((r) => (
            <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="paper-row">
              <Link href={`/exams/papers/${r.id}`} className="font-medium underline-offset-2 hover:underline">
                {r.title}
              </Link>
              <span className="text-muted-foreground">
                {one(r.class_level)?.name_en} · {one(r.subject)?.name_en} · {r.scope_unit_ids.length} chapters
              </span>
              <span className="flex items-center gap-2">
                {r.untaught_override && <Badge variant="outline">override</Badge>}
                <Badge variant={r.status === 'generated' ? 'success' : r.status === 'failed' ? 'destructive' : 'outline'}>{r.status}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
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
