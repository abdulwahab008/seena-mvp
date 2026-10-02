/**
 * FR-J08. The shape fn_withhold_sheet() returns: one term, one whole class,
 * and for each candidate what they owe today and whether their result is
 * being disclosed.
 *
 * This is deliberately a STAFF shape and it carries the money. AC4 is the
 * reason: "when the exam office opens the tabulation sheet, then their
 * computed marks and grades are fully visible internally". The parent-facing
 * counterpart carries one sentence and no figures at all.
 */
export type WithholdReason = 'fee_default' | 'discipline' | 'document_pending';
export type WithholdRelease = 'paid' | 'hardship';

export type WithholdCandidate = {
  enrolment_id: string;
  student_name: string;
  gr_number: string;
  roll_no: number | null;
  section_name: string;
  /** Today's balance in paisa, which is not necessarily the withheld figure. */
  balance_paisa: number;
  is_withheld: boolean;
  withhold_id: string | null;
  reason: WithholdReason | null;
  cutoff_date: string | null;
  /** What was owed as at cutoff_date — frozen when the withhold opened. */
  amount_outstanding_paisa: number | null;
  threshold_paisa: number | null;
  /** The one wording of the refusal, built in the database. */
  message: string | null;
  /** FR-I11's debarment, which is a different refusal at a different desk. */
  is_debarred: boolean;
  last_release_kind: WithholdRelease | null;
  last_release_reason: string | null;
};

export type WithholdSheet = {
  exam_term_id: string;
  exam_term_name: string;
  class_level_id: string;
  threshold_paisa: number;
  can_sync: boolean;
  can_release: boolean;
  candidates: WithholdCandidate[];
};

export type WithholdSyncResult = {
  exam_term_id: string;
  exam_term_name: string;
  cutoff_date: string;
  threshold_paisa: number;
  opened: number;
  refreshed: number;
  released: number;
};

/** Money is paisa as bigint everywhere below the app (FR-K24). */
export function formatPkr(paisa: number | null): string {
  if (paisa === null) return '—';
  return `PKR ${Math.round(paisa / 100).toLocaleString('en-PK')}`;
}

export const WITHHOLD_REASON_LABELS: Record<WithholdReason, string> = {
  fee_default: 'Fee default',
  discipline: 'Discipline hold',
  document_pending: 'Document pending',
};
