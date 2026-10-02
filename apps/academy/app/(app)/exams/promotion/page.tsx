import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { PromotionBoard } from './promotion-board';

/**
 * FR-J04. The end-of-session promotion decisions for one class.
 *
 * The decision is derived from the annual results by the rule shown on this
 * screen; the Principal can override a single candidate with a reason. The
 * enrolment gate in the database is what stops a Detained or Pending student
 * being moved into the next class — this page only reports it.
 */
export default async function PromotionPage() {
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
        <h1 className="text-2xl font-semibold">Promotion decisions</h1>
        <p className="text-sm text-muted-foreground" data-testid="promotion-no-session">
          No current academic session found for this campus.
        </p>
      </div>
    );
  }

  const { classes } = await readMarkEntryOptions(supabase, campus.id, session.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Promotion decisions</h1>
        <p className="text-sm text-muted-foreground">
          FR-J04 — each candidate is promoted, put in compartment or detained from their{' '}
          <Link href="/exams/annual" className="underline">
            annual result
          </Link>{' '}
          by the rule below. A candidate whose result is withheld or incomplete is pending and stays out of the
          promotion batch. A Detained or Pending student cannot be enrolled into the next class.
        </p>
      </div>
      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name}
      </p>
      <PromotionBoard sessionId={session.id} campusId={campus.id} classes={classes} />
    </div>
  );
}
