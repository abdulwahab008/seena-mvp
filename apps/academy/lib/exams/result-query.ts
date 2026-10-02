import type { Board, MarkComponentCode } from '@/lib/validation';
import type { TermResultReady } from '@/lib/exams/mark-query';

/**
 * FR-J02. The shape fn_subject_result_sheet() returns: FR-I16's readiness
 * answer (with FR-I17's staleness on it), the scale the section is graded on,
 * and every candidate's computed subjects — in one round trip.
 */

/** AC2: the component that failed, with the pass mark it missed. */
export type FailedComponent = {
  component: MarkComponentCode;
  obtained: number;
  pass_marks: number;
  max_marks: number;
};

export type SubjectResultRow = {
  subject_id: string;
  subject_name: string;
  obtained: number;
  max_marks: number;
  /** Null when max_marks is 0 — a fully exempt subject has no percentage. */
  pct: number | null;
  grade_label: string | null;
  gpa_point: number | null;
  /** Null when there is nothing to pass or fail: exempt, or withheld. */
  is_pass: boolean | null;
  failed_components: FailedComponent[];
  /** FR-I11's vocabulary: 'AB' / 'EX' / 'DEB', or null for a candidate who sat. */
  report_symbol: string | null;
  /** FR-I11: this candidate is debarred somewhere in the term. Not a fail. */
  is_blocked: boolean;
  /** FR-I17: a mark changed under this result after it was computed. */
  is_stale: boolean;
};

export type SubjectResultCandidate = {
  enrolment_id: string;
  roll_no: number | null;
  student_name: string;
  gr_number: string;
  is_blocked: boolean;
  subjects: SubjectResultRow[];
};

export type SubjectResultSheet = {
  exam_term_id: string;
  section_id: string;
  readiness: TermResultReady;
  board: Board;
  /** Null when no scale is configured for the board — nothing is assumed. */
  grading_scheme: { id: string; name: string; version: number } | null;
  can_compute: boolean;
  computed_at: string | null;
  stale_count: number;
  candidates: SubjectResultCandidate[];
};

/** What a result cell shows: the symbol for a candidate who did not sit, else the grade. */
export function resultDisplay(row: SubjectResultRow): string {
  if (row.is_blocked) return 'WITHHELD';
  if (row.report_symbol === 'EX') return 'EX';
  return row.grade_label ?? '—';
}
