import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { summaryLine, uncapturedMessage, type MasterySheet } from '@/lib/exams/mastery';

/**
 * FR-J07 for parents: their own child's chapters, weakest first. The RPC checks
 * the child belongs to the signed-in guardian, and a paper entered as one total
 * is explained rather than shown as an empty chart.
 */
type SearchParams = { enrolment?: string };

export default async function PortalMasteryPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();
  const { data: enrolments } = await supabase
    .from('enrolment')
    .select('id, student:student_id(name_en)')
    .eq('status', 'active');
  const children = (enrolments ?? []).map((e) => ({ id: e.id, name: (Array.isArray(e.student) ? e.student[0] : e.student)?.name_en ?? '' }));
  const child = children.find((c) => c.id === params.enrolment) ?? children[0];
  const { data } = child ? await supabase.rpc('fn_topic_mastery_sheet', { p_enrolment_id: child.id }) : { data: null };
  const sheet = data as unknown as MasterySheet | null;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold">Chapter mastery</h2>
        <p className="text-sm text-muted-foreground">
          FR-J07 — how your child is doing chapter by chapter, from the per-question marks of their papers.{' '}
          <Link href="/portal/results" className="underline">
            Back to results
          </Link>
        </p>
      </div>
      {children.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {children.map((c) => (
            <Link
              key={c.id}
              href={`/portal/results/mastery?enrolment=${c.id}`}
              className={`rounded-full border px-3 py-1 text-sm ${c.id === child?.id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}
            >
              {c.name}
            </Link>
          ))}
        </div>
      )}
      {!sheet ? (
        <p className="text-sm text-muted-foreground">No enrolled child found on this account.</p>
      ) : (
        <div className="space-y-3" data-testid="portal-mastery">
          {sheet.has_breakdown && <p className="text-sm font-medium" data-testid="portal-mastery-summary">{summaryLine(sheet.topics)}</p>}
          {sheet.topics.map((t) => (
            <p key={`${t.subject_name}-${t.topic_tag}`} className="text-sm">
              {t.subject_name} · {t.topic_tag} · {t.pct === null ? '—' : `${Math.round(Number(t.pct))}%`}
              {t.low_confidence && <span className="ml-2 text-xs text-muted-foreground">low confidence — fewer than 3 questions</span>}
            </p>
          ))}
          {sheet.uncaptured.map((u) => (
            <p key={u.exam_subject_id} className="text-sm text-muted-foreground" data-testid="portal-uncaptured">
              {uncapturedMessage(u)}
            </p>
          ))}
        </div>
      )}
    </div>
  );
}
