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
