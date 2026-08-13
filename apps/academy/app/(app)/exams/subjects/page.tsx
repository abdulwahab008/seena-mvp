import { supabaseServer } from '@/lib/supabase/server';
import { readExamSubjectSetup } from '@/lib/exams/subject-query';
import { SubjectSetup } from './subject-setup';

/**
 * FR-I02. Max and pass marks per component for each class-subject in a term.
 *
 * The role gate mirrors upsert_exam_subject()'s own. Reading the setup — and
 * the mark-entry readiness preview in particular — is deliberately open to
 * anyone in campus scope, because AC4's question is asked BY a teacher.
 */
const SETUP_ROLES = ['super_admin', 'owner', 'principal', 'exam_controller'];

type SearchParams = { term?: string };

export default async function ExamSubjectsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  // Same campus/session derivation as every other campus-scoped page here.
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

  // Only a selectable term can be configured against — a draft term is not
  // yet the structure anything rolls up into (FR-I01).
  const { data: terms } = campus && session
    ? await supabase
        .from('v_exam_term_selectable')
        .select('id, code, name')
        .eq('campus_id', campus.id)
        .eq('session_id', session.id)
        .order('sequence')
    : { data: [] };
  // A view's columns are all nullable in the generated types even when the
  // underlying columns are NOT NULL; narrow once here rather than sprinkling
  // non-null assertions through the render.
  const termRows = (terms ?? []).filter((t): t is { id: string; code: string; name: string } => t.id !== null);
  const term = termRows.find((t) => t.id === params.term) ?? termRows[0];

  if (!campus || !session || !term) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Exam subjects</h1>
        <p className="text-sm text-muted-foreground" data-testid="exam-subjects-no-term">
          No activated exam term found for this campus and session. Define and activate a term set first.
        </p>
      </div>
    );
  }

  const { configured, options } = await readExamSubjectSetup(supabase, campus.id, session.id, term.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Exam subjects</h1>
        <p className="text-sm text-muted-foreground">
          FR-I02 — max and pass marks per component, so mark entry and pass/fail logic have an unambiguous denominator.
          Configured once per class; every section of that class inherits it.
        </p>
      </div>

      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name} &middot; {term.name}
      </p>

      <SubjectSetup
        examTermId={term.id}
        examTermLabel={term.name}
        canWrite={SETUP_ROLES.includes(role)}
        configured={configured}
        options={options}
      />
    </div>
  );
}
