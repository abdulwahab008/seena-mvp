import { supabaseServer } from '@/lib/supabase/server';
import { formatPkr } from '@/lib/challan/html';
import { BoardFormsBoard } from './board-forms-board';

/**
 * FR-T12. The board examination form: who is registered for which subjects,
 * what the board charges them, what the school collected, and the file.
 *
 * The reconciliation is the point of the page. The school collects the board
 * fee from parents and remits it to the board, so a candidate who has paid
 * nothing is the school's loss; the screen names them before the file is made.
 */
export default async function BoardFormsPage() {
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
        <h1 className="text-2xl font-semibold">Board examination forms</h1>
        <p className="text-sm text-muted-foreground" data-testid="board-forms-no-session">
          No current academic session found for this campus.
        </p>
      </div>
    );
  }

  const [{ data: schedule }, { data: registrations }] = await Promise.all([
    supabase
      .from('board_fee_schedule')
      .select('id, board_code, session_year, candidate_category, per_candidate_amount, per_paper_amount, effective_from, effective_to')
      .order('board_code')
      .order('session_year', { ascending: false })
      .order('candidate_category')
      .order('effective_from', { ascending: false }),
    supabase
      .from('v_board_exam_reconciliation')
      .select('registration_id, board_code, session_year, candidate_category, student_name, gr_number, roll_no, computed_paisa, collected_paisa, payment_status')
      .eq('session_id', session.id)
      .order('student_name')
      .limit(500),
  ]);

  const rows = (schedule ?? []).map((s) => ({
    id: s.id,
    label: `${s.board_code} ${s.session_year} · ${s.candidate_category}`,
    perCandidate: formatPkr(Number(s.per_candidate_amount)),
    perPaper: formatPkr(Number(s.per_paper_amount)),
    window: `${s.effective_from} → ${s.effective_to ?? 'open'}`,
  }));
  const regs = (registrations ?? []).map((r) => ({
    id: r.registration_id as string,
    name: r.student_name ?? '',
    gr: r.gr_number ?? '',
    board: r.board_code ?? '',
    year: r.session_year ?? 0,
    category: r.candidate_category ?? '',
    roll: r.roll_no,
    computed: r.computed_paisa === null ? '—' : formatPkr(Number(r.computed_paisa)),
    collected: formatPkr(Number(r.collected_paisa ?? 0)),
    status: r.payment_status ?? '',
  }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Board examination forms</h1>
        <p className="text-sm text-muted-foreground">
          FR-T12 — register candidates with their subject combination, price each on the board&rsquo;s fee schedule in
          force on their exam session date, compare the total with what parents paid, and export the form. A group
          missing a mandatory subject blocks the export and names the subject. An improvement candidate is exported
          with only the subjects being improved, at the per-paper rate.
        </p>
      </div>
      <p className="text-sm text-muted-foreground">
        {campus.name} &middot; {session.name}
      </p>
      <BoardFormsBoard campusId={campus.id} sessionId={session.id} schedule={rows} registrations={regs} />
    </div>
  );
}
