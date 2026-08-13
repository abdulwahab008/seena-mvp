import { supabaseServer } from '@/lib/supabase/server';
import { readMarkEntryOptions } from '@/lib/exams/mark-query';
import { MARK_APPROVER_ROLES } from '@/lib/validation';
import { ApprovalBoard } from './approval-board';

/**
 * FR-I16. The Exam Controller's sign-off screen.
 *
 * The role gate here is a courtesy, not the control: fn_approve_marks() runs
 * the same list server-side and fn_mark_approval_queue() returns can_approve
 * from the JWT, so a user who reached this page another way still cannot
 * approve anything. Showing a board with every button disabled would be worse
 * than saying why.
 */
type SearchParams = { term?: string };

export default async function MarkApprovalsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const params = await searchParams;
  const supabase = await supabaseServer();

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: appUser } = await supabase.from('app_user').select('app_role').eq('user_id', user!.id).single();
  const role = appUser?.app_role ?? 'none';

  if (!MARK_APPROVER_ROLES.includes(role as (typeof MARK_APPROVER_ROLES)[number])) {
    return (
      <div className="space-y-6">
        <h1 className="text-2xl font-semibold">Mark approval</h1>
        <p className="text-sm text-muted-foreground" data-testid="mark-approvals-forbidden">
          Only an Exam Controller, Principal, Owner or Super Admin can approve a section&rsquo;s marks.
        </p>
      </div>
    );
  }

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
        <h1 className="text-2xl font-semibold">Mark approval</h1>
        <p className="text-sm text-muted-foreground" data-testid="mark-approvals-no-term">
          No activated exam term found for this campus and session.
        </p>
      </div>
    );
  }

  const { sections } = await readMarkEntryOptions(supabase, campus.id, session.id);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Mark approval</h1>
        <p className="text-sm text-muted-foreground">
          FR-I16 — approving a paper for a section makes its marks read-only for everyone, including the teacher who
          entered them and any service-role job. A set is only approvable once every candidate has a mark or an exam
          status.
        </p>
      </div>

      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name} &middot; {term.name}
      </p>

      <ApprovalBoard examTermId={term.id} termName={term.name} sections={sections} />
    </div>
  );
}
