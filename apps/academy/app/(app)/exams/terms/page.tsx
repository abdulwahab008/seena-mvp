import { supabaseServer } from '@/lib/supabase/server';
import { TermSetEditor, type ExamTermRow } from './term-set-editor';

/**
 * FR-I01. Define the exam terms of a session and their weightage, then
 * activate the set — which the database refuses unless the counting terms
 * total exactly 100.00%.
 *
 * The role gate mirrors upsert_exam_term()'s own; the database enforces it
 * again regardless of what this page renders.
 */
const TERM_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'];

export default async function ExamTermsPage() {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  // Alphabetically-first active campus and that campus's current session,
  // the same derivation every other campus-scoped page in this app uses
  // (academic-setup/curriculum, fees/challans, fees/reports). Deriving the
  // acting user's own campus assignment instead is a cross-cutting gap
  // shared by all of them, not one to solve here.
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code').limit(1);
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

  const { data: terms } = campus && session
    ? await supabase
        .from('exam_term')
        .select('id, code, name, name_ur, sequence, weight_pct, counts_toward_annual, status')
        .eq('campus_id', campus.id)
        .eq('session_id', session.id)
        .order('sequence')
    : { data: [] as ExamTermRow[] };

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Exam terms</h1>
        <p className="text-sm text-muted-foreground">
          FR-I01 — the term structure every mark, aggregate and report card rolls up against. A term set can only be
          activated when its counting terms total exactly 100.00%, and a term&rsquo;s weightage is frozen once marks have been
          approved against it.
        </p>
      </div>

      {!campus || !session ? (
        <p className="text-sm text-muted-foreground" data-testid="exam-terms-no-session">
          No active campus or current session found.
        </p>
      ) : (
        <>
          <p className="text-sm text-muted-foreground">
            {campus.name} &middot; {session.name}
          </p>
          <TermSetEditor
            campusId={campus.id}
            sessionId={session.id}
            canWrite={TERM_ROLES.includes(role)}
            terms={(terms ?? []) as ExamTermRow[]}
          />
        </>
      )}
    </div>
  );
}
