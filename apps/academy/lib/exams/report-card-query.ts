/**
 * FR-J09. The shape fn_report_card_sheet() returns: one section, one term,
 * and for each candidate the current issued revision plus — if none can be
 * produced — the sentence the refusal itself would raise.
 *
 * The blocked_reason is the gate's own message rather than a code the screen
 * translates, so a button that is disabled and an attempt that is refused
 * cannot give two different explanations of the same fact.
 */
export type ReportCardCandidate = {
  enrolment_id: string;
  student_name: string;
  gr_number: string;
  roll_no: number | null;
  report_card_id: string | null;
  revision_no: number | null;
  rendered_at: string | null;
  blocked_reason: string | null;
};

export type ReportCardSheet = {
  exam_term_id: string;
  exam_term_name: string;
  section_id: string;
  section_name: string;
  can_print: boolean;
  candidates: ReportCardCandidate[];
};
