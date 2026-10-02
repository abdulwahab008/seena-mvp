import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { getExamOfficeScope, one } from '@/lib/exams/office-scope';
import { ModerationForm, ReverseForm } from './moderation-forms';

/**
 * FR-I15. Bounded, reasoned moderation of one section's theory marks, before
 * approval. The controller sees the section mean against the class mean, applies
 * an adjustment within the campus cap with a reason, and sees who hit the
 * component maximum. A section can be moderated once; changing it means
 * reversing the first moderation. After approval the only way in is break-glass.
 */
type SearchParams = { term?: string; subject?: string; section?: string };
type Context = {
  max_marks: number;
  present_with_marks: number;
  section_mean_pct: number | null;
  class_mean_pct: number | null;
  cap_delta: number;
  cap_pct: number | null;
  open_moderation_id: string | null;
  approved: boolean;
};

export default async function ModerationPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const scope = await getExamOfficeScope(supabase);

  const header = (
    <div>
      <h1 className="text-2xl font-semibold">Moderation</h1>
      <p className="text-sm text-muted-foreground">
        FR-I15 — adjust a section whose paper proved unfair: bounded by the campus cap, reasoned, applied once and only before approval. The original marks are always kept.
      </p>
    </div>
  );
  if (!scope.campus || !scope.session) return <div className="space-y-6">{header}<p className="text-sm text-muted-foreground">No active campus or current session found.</p></div>;
  if (!scope.canWrite) {
    return (
      <div className="space-y-6">
        {header}
        <p className="text-sm text-muted-foreground" data-testid="moderation-forbidden">Moderation is the exam controller&rsquo;s and the Principal&rsquo;s.</p>
      </div>
    );
  }
  const campus = scope.campus;

  const { data: terms } = await supabase.from('exam_term').select('id, name').eq('campus_id', campus.id).eq('session_id', scope.session.id).order('sequence');
  const term = (terms ?? []).find((t) => t.id === sp.term) ?? terms?.[0] ?? null;
  const { data: subjectRows } = term
    ? await supabase.from('exam_subject').select('id, class_subject:class_subject_id(class_level_id, session_id, class_level:class_level_id(name_en, ordinal), subject:subject_id(name_en))').eq('exam_term_id', term.id)
    : { data: [] };
  const subjects = (subjectRows ?? [])
    .map((s) => {
      const cs = one(s.class_subject);
      return { id: s.id, classLevelId: cs?.class_level_id ?? '', sessionId: cs?.session_id ?? '', ordinal: one(cs?.class_level)?.ordinal ?? 0, label: `${one(cs?.class_level)?.name_en ?? ''} · ${one(cs?.subject)?.name_en ?? ''}` };
    })
    .sort((a, b) => a.ordinal - b.ordinal || a.label.localeCompare(b.label));
  const subject = subjects.find((s) => s.id === sp.subject) ?? subjects[0] ?? null;
  const { data: sectionRows } = subject
    ? await supabase.from('class_section').select('id, name').eq('class_level_id', subject.classLevelId).eq('session_id', subject.sessionId).eq('campus_id', campus.id).eq('is_active', true).order('name')
    : { data: [] };
  const section = (sectionRows ?? []).find((s) => s.id === sp.section) ?? sectionRows?.[0] ?? null;

  const { data: ctxData } = subject && section ? await supabase.rpc('fn_moderation_context', { p_exam_subject_id: subject.id, p_section_id: section.id }) : { data: null };
  const ctx = ctxData as unknown as Context | null;

  const { data: history } = subject
    ? await supabase
        .from('mark_moderation')
        .select('id, section_id, delta, reason, applied_at, reversed_at, reverse_reason, affected_count, capped_count, section_mean_pct, class_mean_pct, section:section_id(name)')
        .eq('exam_subject_id', subject.id)
        .order('applied_at', { ascending: false })
    : { data: [] };

  return (
    <div className="space-y-6">
      {header}
      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Exam term</span>
          <select name="term" defaultValue={term?.id} className="h-9 rounded-md border bg-background px-2">
            {(terms ?? []).map((t) => (
              <option key={t.id} value={t.id}>
                {t.name}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Paper</span>
          <select name="subject" defaultValue={subject?.id} className="h-9 rounded-md border bg-background px-2">
            {subjects.map((s) => (
              <option key={s.id} value={s.id}>
                {s.label}
              </option>
            ))}
          </select>
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">Section</span>
          <select name="section" defaultValue={section?.id} className="h-9 rounded-md border bg-background px-2">
            {(sectionRows ?? []).map((s) => (
              <option key={s.id} value={s.id}>
                {s.name}
              </option>
            ))}
          </select>
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>

      {!subject || !section || !ctx ? (
        <p className="text-sm text-muted-foreground">Choose an exam paper with marks entered.</p>
      ) : (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">
                {subject.label} · section {section.name}
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-3 text-sm">
              <div className="flex flex-wrap items-center gap-x-6 gap-y-1" data-testid="moderation-context">
                <span>
                  Section mean: <strong>{ctx.section_mean_pct === null ? '—' : `${ctx.section_mean_pct}%`}</strong>
                </span>
                <span>
                  Class mean: <strong>{ctx.class_mean_pct === null ? '—' : `${ctx.class_mean_pct}%`}</strong>
                </span>
                <span>{ctx.present_with_marks} present candidates with a theory mark</span>
                <span>Cap: ±{ctx.cap_delta} marks{ctx.cap_pct !== null ? ` (and ${ctx.cap_pct}% of ${ctx.max_marks})` : ''}</span>
                {ctx.approved && <Badge variant="destructive">approved</Badge>}
              </div>

              {ctx.approved ? (
                <p className="text-destructive" role="alert" data-testid="moderation-approved">
                  These marks are approved, so they can no longer be moderated. Reopen them with a break-glass unlock first.
                </p>
              ) : ctx.open_moderation_id ? (
                <div className="space-y-2" data-testid="moderation-applied">
                  <p>This section has already been moderated. To change it, reverse the moderation first.</p>
                  <ReverseForm moderationId={ctx.open_moderation_id} />
                </div>
              ) : (
                <ModerationForm key={`${subject.id}-${section.id}`} examSubjectId={subject.id} sectionId={section.id} cap={ctx.cap_delta} />
              )}
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">Moderation history for this paper</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2 text-sm" data-testid="moderation-history">
              {(history ?? []).length === 0 && <p className="text-muted-foreground">No section of this paper has been moderated.</p>}
              {(history ?? []).map((h) => (
                <p key={h.id} data-testid="moderation-row" data-reversed={h.reversed_at ? 'true' : 'false'}>
                  Section {one(h.section)?.name}: {h.delta > 0 ? '+' : ''}
                  {h.delta} marks ({h.affected_count} candidates, {h.capped_count} capped) on {new Date(h.applied_at).toLocaleDateString('en-GB')} — {h.reason}
                  {h.reversed_at ? ` — reversed: ${h.reverse_reason}` : ''}
                </p>
              ))}
            </CardContent>
          </Card>
        </>
      )}
    </div>
  );
}
