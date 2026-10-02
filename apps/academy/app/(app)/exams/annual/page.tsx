import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { AnnualBoard } from './annual-board';

/**
 * FR-J03. The weighted annual result for one section of the current session.
 *
 * Nothing here computes on load: signing off a section's last paper already
 * chained into the aggregate. This screen shows what came out, says what each
 * term was worth, and is loud about the two states a report card must not be
 * printed from — provisional, and stale.
 */
export default async function AnnualResultsPage() {
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
        <h1 className="text-2xl font-semibold">Annual results</h1>
        <p className="text-sm text-muted-foreground" data-testid="annual-no-session">
          No current academic session found for this campus.
        </p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Annual results</h1>
        <p className="text-sm text-muted-foreground">
          FR-J03 — each subject&rsquo;s year is the weighted sum of its{' '}
          <Link href="/exams/results" className="underline">
            term results
          </Link>
          , using the{' '}
          <Link href="/exams/terms" className="underline">
            term weightages
          </Link>
          . The arithmetic rounds once, at the end. A candidate who joined mid-session has the missing term&rsquo;s
          weight redistributed across the terms they sat, and the report card says so.
        </p>
      </div>

      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name}
      </p>

      <AnnualBoard sessionId={session.id} sections={sections} />
    </div>
  );
}
