/**
 * FR-J03. The shape fn_annual_result_sheet() returns: every term of the
 * session with what it is worth and whether it counts, plus each candidate's
 * weighted subjects — in one round trip.
 */
export type AnnualResultStatus = 'provisional' | 'final';

/**
 * FR-I01. weight_bp is the number the aggregate is computed from; weight_pct
 * is the same number for a human. counts_toward_annual false means the term is
 * printed on the report card and is outside the 100% total.
 */
export type AnnualTerm = {
  exam_term_id: string;
  code: string;
  name: string;
  sequence: number;
  weight_bp: number;
  weight_pct: number;
  counts_toward_annual: boolean;
  ready: boolean;
};

export type AnnualSubjectRow = {
  subject_id: string;
  subject_name: string;
  /** Null when nothing contributed a percentage — withheld, or exempt all year. */
  weighted_pct: number | null;
  grade_label: string | null;
  gpa_point: number | null;
  is_pass: boolean | null;
  status: AnnualResultStatus;
  terms_counted: number;
  terms_total: number;
  /** AC3: "pro-rated, 2 of 3 terms", or null when every term counted. */
  proration_note: string | null;
  /** FR-I11: debarred somewhere in the year. Not a fail. */
  is_blocked: boolean;
  /** FR-I17: a contributing term result changed or moved under this figure. */
  is_stale: boolean;
};

export type AnnualCandidate = {
  enrolment_id: string;
  roll_no: number | null;
  student_name: string;
  gr_number: string;
  is_blocked: boolean;
  subjects: AnnualSubjectRow[];
};

export type AnnualResultSheet = {
  session_id: string;
  section_id: string;
  class_level_id: string;
  terms: AnnualTerm[];
  /** Counting terms this section has not finished marking. */
  pending_terms: string[];
  can_compute: boolean;
  computed_at: string | null;
  stale_count: number;
  provisional_count: number;
  candidates: AnnualCandidate[];
};

/** What an annual grade cell shows. A withheld year is not an F. */
export function annualDisplay(row: AnnualSubjectRow): string {
  if (row.is_blocked) return 'WITHHELD';
  return row.grade_label ?? '—';
}
