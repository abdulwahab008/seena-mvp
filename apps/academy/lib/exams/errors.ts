/**
 * FR-I01. The named errors upsert_exam_term(), activate_exam_terms(),
 * set_exam_term_weight() and their triggers raise, turned into something a
 * person can read.
 *
 * Two of them are passed through UNTRANSLATED and that is deliberate:
 *
 *   * "Term weightage must total 100.00%, currently 90.00%" is the sentence
 *     FR-I01's acceptance criteria assert, down to the two decimal places.
 *     Rewriting it here would mean the screen and the database disagree
 *     about the wording of the one message this FR is explicit about.
 *   * "exam term weightage is locked by approved marks — raise a
 *     result-recompute request" already says what happened and what to do
 *     next; a paraphrase would only make it vaguer.
 *
 * Lives in lib/ rather than in actions.ts because a 'use server' module may
 * only export async functions.
 */
const PASS_THROUGH = ['Term weightage must total', 'exam term weightage is locked by approved marks'];

export function examTermError(message: string): string {
  const verbatim = PASS_THROUGH.find((p) => message.includes(p));
  if (verbatim) return message.slice(message.indexOf(verbatim));

  if (message.includes('WEIGHT_PRECISION')) {
    return 'Weightage supports at most two decimal places.';
  }
  if (message.includes('WEIGHT_OUT_OF_RANGE')) return 'Weightage must be between 0 and 100.';
  if (message.includes('EXAM_TERM_NAME_REQUIRED')) return 'A term needs a code and a name.';
  if (message.includes('EXAM_TERM_NOT_DRAFT')) {
    return 'This term is already activated — removing it now is a result correction, not a setup edit.';
  }
  if (message.includes('EXAM_TERM_NOT_ACTIVE')) return 'Only an activated term can be locked.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('SESSION_NOT_FOUND')) return 'That academic session is not available for this campus.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('duplicate key') && message.includes('uq_exam_term_seq')) {
    return 'Another term already holds that position in the sequence.';
  }
  if (message.includes('duplicate key') && message.includes('uq_exam_term_code')) {
    return 'A term with that code already exists in this session.';
  }
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}

/**
 * FR-I02. Same shape as examTermError above. 'pass marks cannot exceed
 * maximum marks' and 'exam setup is locked by approved marks' are passed
 * through untranslated for the same reason: the first is asserted wording,
 * the second already says what to do next.
 */
const SUBJECT_PASS_THROUGH = ['pass marks cannot exceed maximum marks', 'exam setup is locked by approved marks'];

export function examSubjectError(message: string): string {
  const verbatim = SUBJECT_PASS_THROUGH.find((p) => message.includes(p));
  if (verbatim) return message.slice(message.indexOf(verbatim));

  if (message.includes('COMPONENTS_REQUIRED')) {
    return 'Add at least one component — a subject with no components has no denominator.';
  }
  if (message.includes('COMPONENT_DUPLICATED')) return 'Each component can only be configured once.';
  if (message.includes('MARKS_OUT_OF_RANGE')) {
    return 'Maximum marks must be above zero and pass marks cannot be negative.';
  }
  if (message.includes('SUBJECT_NOT_EXAMINABLE')) return 'That subject is not examinable.';
  if (message.includes('CLASS_SUBJECT_TERM_MISMATCH')) {
    return 'That subject belongs to a different campus or session than this exam term.';
  }
  if (message.includes('CLASS_SUBJECT_NOT_FOUND')) return 'That class subject is not in the curriculum.';
  if (message.includes('EXAM_SUBJECT_NOT_FOUND')) return 'Exam subject not found.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('SECTION_NOT_FOUND')) return 'Section not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}

/**
 * FR-I12. trg_mark_range_check raises the three sentences a teacher reads in
 * a cell — "max 65", "whole numbers only", "marks cannot be negative" — so
 * those pass through verbatim: the grid shows the same wording before the
 * round trip, and the two disagreeing would be worse than either.
 */
const MARK_PASS_THROUGH = [
  /^max \d+$/,
  /^whole numbers only$/,
  /^at most \d decimal places?$/,
  /^marks cannot be negative$/,
  /^marks are locked by approval/,
  // FR-I11: both name the candidate's status or the way through, and a
  // paraphrase would only make either vaguer.
  /^candidate is marked (Absent|Exempt|Debarred) for this paper$/,
  /^candidate exam status is locked by approved marks/,
];

export function markEntryError(message: string): string {
  const line = message.split('\n')[0]?.trim() ?? message;
  if (MARK_PASS_THROUGH.some((p) => p.test(line))) return line;

  if (message.includes('MARK_COMPONENT_NOT_CONFIGURED')) {
    return 'That component is not part of this paper — reload the grid.';
  }
  if (message.includes('MARK_ENROLMENT_MISMATCH')) {
    return 'That candidate is not in the class this paper is set for.';
  }
  if (message.includes('MARK_PAYLOAD_INVALID')) return 'Could not read those marks — reload the grid.';
  if (message.includes('EXAM_STATUS_OFFICE_ONLY')) {
    return 'Only the exam office can record an exemption or a debarment.';
  }
  if (message.includes('ABSENCE_REASON_REQUIRED')) return 'Choose a reason code.';
  if (message.includes('REASON_NOT_APPLICABLE')) return 'A candidate who sat the paper has no absence reason.';
  if (message.includes('MARKS_ALREADY_ENTERED')) {
    return 'Clear this candidate\u2019s marks for the paper before recording them as not present.';
  }
  if (message.includes('MARK_PRECISION_OUT_OF_RANGE')) return 'Mark precision must be 0, 1 or 2 decimal places.';
  if (message.includes('ENROLMENT_NOT_FOUND')) return 'That candidate is no longer enrolled.';
  if (message.includes('EXAM_SUBJECT_NOT_FOUND')) return 'This paper has no exam setup yet.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('SECTION_NOT_FOUND')) return 'Section not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('FORBIDDEN')) return 'You do not teach this class subject.';
  return 'Could not save those marks.';
}
