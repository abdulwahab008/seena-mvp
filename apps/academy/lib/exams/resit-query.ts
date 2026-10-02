import type { ResitPolicy } from '@/lib/validation';

/**
 * FR-J14. The shape fn_resit_sheet() returns: everyone on the term's re-sit
 * list with the attempts on record and what is currently published.
 */
export type ResitBasis = 'failed' | 'absent_medical' | 'absent_other' | 'principal_exception';

export type ResitAttempt = { attempt_no: number; type: 'resit' | 'improvement'; obtained: number; sat_on: string };

export type ResitRow = {
  enrolment_id: string;
  exam_subject_id: string;
  student_name: string;
  gr_number: string;
  roll_no: number | null;
  subject_name: string;
  eligible: boolean;
  basis: ResitBasis;
  exception_reason: string | null;
  attempts: ResitAttempt[];
  published: {
    attempt_no: number;
    published_obtained: number;
    raw_obtained: number;
    substituted: boolean;
    max_marks: number;
  } | null;
};

export type ResitSheet = {
  exam_term_id: string;
  policy: ResitPolicy;
  can_grant: boolean;
  rows: ResitRow[];
};

export const POLICY_LABEL: Record<ResitPolicy, string> = {
  latest: 'Latest attempt publishes',
  best_of: 'Best of all attempts publishes',
  capped_at_pass: 'Re-sit capped at the pass mark; best attempt publishes',
};

export const BASIS_LABEL: Record<ResitBasis, string> = {
  failed: 'Failed the paper',
  absent_medical: 'Absent — medical',
  absent_other: 'Absent — no medical reason',
  principal_exception: 'Principal exception',
};

export function resitError(message: string): string {
  if (message.includes('RESIT_NOT_ELIGIBLE')) return 'This candidate is not eligible for a re-sit. A Principal can record an exception.';
  if (message.includes('IMPROVEMENT_REQUIRES_PASS')) return 'An improvement attempt is for a paper the candidate passed; a failed paper is a re-sit.';
  if (message.includes('MARKS_OUT_OF_RANGE')) return 'The marks are outside the paper’s maximum.';
  if (message.includes('SAT_ON_INVALID')) return 'Choose the date the paper was sat (not in the future).';
  if (message.includes('ATTEMPT_NOT_ALLOWED')) return 'An exempt or debarred candidate has no paper to re-sit.';
  if (message.includes('EXCEPTION_REASON_REQUIRED')) return 'An exception needs a reason.';
  if (message.includes('POLICY_INVALID')) return 'That is not a valid policy.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('ENROLMENT_NOT_FOUND')) return 'That candidate is no longer enrolled.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete the re-sit action.';
}
