import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { MarkGrid } from './mark-grid';
import { pickActiveCampus } from '@/lib/campus-context';

/**
 * FR-I12. The teacher's mark entry grid — the real one. FR-I02 rendered a
 * read-only preview of fn_exam_entry_readiness() on the exam-subject setup
 * screen and labelled it a stub pending this FR; that panel is gone, and this
 * is the single surface. Whether the caller may WRITE is answered server-side
 * by fn_mark_entry_sheet()'s can_enter and enforced by fn_upsert_marks(), so
 * this page needs no role gate of its own.
 */
type SearchParams = { term?: string };

export default async function MarkEntryPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const { data: campuses } = await supabase
    .from('campus')
    .select('id, name')
    .eq('status', 'active')
    .order('code')
    ;
  const campus = (await pickActiveCampus(campuses));
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
  // View columns are all nullable in the generated types even when the
  // underlying ones are NOT NULL; narrow once here.
  const termRows = (terms ?? []).filter((t): t is { id: string; code: string; name: string } => t.id !== null);
  const term = termRows.find((t) => t.id === params.term) ?? termRows[0];

  if (!campus || !session || !term) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Mark entry</h1>
        <p className="text-sm text-muted-foreground" data-testid="mark-entry-no-term">
          No activated exam term found for this campus and session. The exam office defines and activates a term set
          first.
        </p>
      </div>
    );
  }

  const { sections, subjects } = await readMarkEntryOptions(supabase, campus.id, session.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Mark entry</h1>
        <p className="text-sm text-muted-foreground">
          Obtained marks per candidate per component, validated against the configured maximum. Every cell
          autosaves as a draft; nothing is submitted by typing it.
        </p>
      </div>

      <div className="flex flex-wrap items-center gap-2 text-sm">
        <span className="text-muted-foreground">
          {campus.name} &middot; {session.name} &middot;
        </span>
        {termRows.map((t) => (
          <Link
            key={t.id}
            href={`/exams/marks?term=${t.id}`}
            aria-current={t.id === term.id ? 'page' : undefined}
            className={
              t.id === term.id
                ? 'rounded-full bg-primary px-3 py-1 text-primary-foreground'
                : 'rounded-full border px-3 py-1 text-muted-foreground hover:text-foreground'
            }
            data-testid={`mark-entry-term-${t.code}`}
          >
            {t.name}
          </Link>
        ))}
      </div>

      <MarkGrid examTermId={term.id} sections={sections} subjects={subjects} />
    </div>
  );
}
