import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { PacketBoard } from './packet-board';

/**
 * FR-J11. The report card handed over with next term's fee challan.
 *
 * The challan is the fee module's. This page chooses which one belongs with
 * which card, assembles the PDF, and says plainly which candidates have a card
 * but no challan to go with it.
 */
type SearchParams = { term?: string };

export default async function PacketsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
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
        <h1 className="text-2xl font-semibold">Report card packets</h1>
        <p className="text-sm text-muted-foreground" data-testid="packets-no-term">
          No activated exam term found for this campus and session.
        </p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Report card packets</h1>
        <p className="text-sm text-muted-foreground">
          FR-J11 — the issued{' '}
          <Link href="/exams/results#report-cards" className="underline">
            report card
          </Link>{' '}
          followed by next cycle&rsquo;s 3-copy challan, one PDF, so collection starts the day parents collect results.
          The amount is read from the fee module and printed as it stands; nothing here recalculates a fee. A withheld
          result produces no card and no packet, and its challan stays in the fee module.
        </p>
      </div>
      {termRows.length > 1 && (
        <div className="flex flex-wrap gap-2" data-testid="packet-term-selector">
          {termRows.map((t) => (
            <Link
              key={t.id}
              href={`/exams/packets?term=${t.id}`}
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
      <PacketBoard examTermId={term.id} sections={sections} />
    </div>
  );
}
