import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { ResultBoard } from './result-board';

/**
 * FR-J02. The computed per-subject results for one section of one term.
 *
 * Nothing here computes on load: approving the last paper of a section already
 * did that. This screen shows what came out, names the scale it was graded on,
 * and is loud about a result a break-glass correction has left stale.
 */
type SearchParams = { term?: string };

export default async function SubjectResultsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
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

  const { data: terms } =
    campus && session
      ? await supabase
          .from('v_exam_term_selectable')
          .select('id, code, name')
          .eq('campus_id', campus.id)
          .eq('session_id', session.id)
          .order('sequence')
      : { data: [] };
  const termRows = (terms ?? []).filter((t): t is { id: string; code: string; name: string } => t.id !== null);
  const term = termRows.find((t) => t.id === params.term) ?? termRows[0];

  if (!campus || !session || !term) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Term results</h1>
        <p className="text-sm text-muted-foreground" data-testid="results-no-term">
          No activated exam term found for this campus and session.
        </p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Term results</h1>
        <p className="text-sm text-muted-foreground">
          FR-J02 — per-subject results are computed the moment a section&rsquo;s last paper is signed off. An exempt
          subject leaves the denominator, an absence scores zero against the full maximum, and a subject can clear its
          aggregate and still fail on a component&rsquo;s own pass mark. The grade comes from the{' '}
          <Link href="/exams/grading" className="underline">
            board grade scale
          </Link>{' '}
          that was in effect for this session, and stays on that version afterwards.
        </p>
      </div>

      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name} &middot; {term.name}
      </p>

      <ResultBoard examTermId={term.id} termName={term.name} sections={sections} />
    </div>
  );
}
