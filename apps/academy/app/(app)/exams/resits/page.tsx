import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { ResitBoard } from './resit-board';

/**
 * FR-J14. Re-sit and improvement attempts, kept beside the original paper.
 *
 * The published mark is whichever attempt the campus policy says counts; the
 * raw marks of every attempt stay on this screen and in the internal record.
 */
type SearchParams = { term?: string };

export default async function ResitsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
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
        <h1 className="text-2xl font-semibold">Re-sits and improvements</h1>
        <p className="text-sm text-muted-foreground" data-testid="resits-no-term">
          No activated exam term found for this campus and session.
        </p>
      </div>
    );
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Re-sits and improvements</h1>
        <p className="text-sm text-muted-foreground">
          FR-J14 — a re-sit or improvement is recorded as a separate attempt and the original is never overwritten. The
          campus policy decides which attempt is published; the{' '}
          <Link href="/exams/results" className="underline">
            term result
          </Link>
          , rank, annual aggregate, promotion and transcript all follow that one answer. A published mark taken from a
          later attempt is marked R on the report card.
        </p>
      </div>
      {termRows.length > 1 && (
        <div className="flex flex-wrap gap-2">
          {termRows.map((t) => (
            <Link
              key={t.id}
              href={`/exams/resits?term=${t.id}`}
              className={`rounded-full border px-3 py-1 text-sm ${t.id === term.id ? 'bg-primary text-primary-foreground' : 'text-muted-foreground'}`}
            >
              {t.name}
            </Link>
          ))}
        </div>
      )}
      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name} &middot; {term.name}
      </p>
      <ResitBoard examTermId={term.id} campusId={campus.id} />
    </div>
  );
}
