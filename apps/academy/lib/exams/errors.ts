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

  // FR-I16. 'marks_locked' is the acceptance criterion's own token rather
  // than a sentence, so this is the one place it becomes one.
  if (line === 'marks_locked') {
    return 'These marks were approved and signed off — a correction needs a break-glass unlock.';
  }

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

/**
 * FR-I16. fn_approve_marks() builds two of its refusals as SENTENCES rather
 * than as codes, because the acceptance criterion asserts the LISTING —
 * "approval is refused and the 2 GR numbers are listed" — and a code the UI
 * expands cannot name rows the database found. Those pass through verbatim.
 */
const APPROVAL_PASS_THROUGH = [
  /^\d+ candidates? (has|have) neither a mark nor an exam status: /,
  /^\d+ candidates? (is|are) missing a component mark: /,
  // FR-I14, in the same shape and for the same reason: the refusal names the
  // candidates whose scripts a machine read and nobody checked.
  /^\d+ candidates? (has|have) an OCR mark no teacher has confirmed: /,
];

export function markApprovalError(message: string): string {
  const line = message.split('\n')[0]?.trim() ?? message;
  if (APPROVAL_PASS_THROUGH.some((p) => p.test(line))) return line;

  if (message.includes('MARKS_ALREADY_APPROVED')) {
    return 'This set is already signed off. Reopening it is a break-glass unlock.';
  }
  if (message.includes('SECTION_NOT_IN_EXAM_SUBJECT')) {
    return 'That section does not sit this paper — check the class and stream.';
  }
  if (message.includes('EXAM_SETUP_PENDING')) {
    return 'This paper has no components configured, so it has no denominator to sign off.';
  }
  if (message.includes('EXAM_SUBJECT_NOT_FOUND')) return 'This paper has no exam setup yet.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('SECTION_NOT_FOUND')) return 'Section not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to approve marks.';
  return 'Could not approve those marks.';
}

/**
 * FR-I17. Every refusal on the break-glass path is a named code, deliberately:
 * unlike FR-I16's completeness message there is nothing here the database
 * knows and the screen does not, so a sentence built in SQL would only be a
 * second place for the wording to live.
 */
export function markUnlockError(message: string): string {
  if (message.includes('UNLOCK_SELF_APPROVAL')) {
    return 'A break-glass request cannot be decided by the person who raised it.';
  }
  if (message.includes('UNLOCK_APPROVER_ONLY')) {
    return 'Only a Principal, Owner or Super Admin can grant a break-glass unlock.';
  }
  if (message.includes('UNLOCK_REASON_REQUIRED')) {
    return 'Say why in at least 10 characters — it is what the exceptions report shows.';
  }
  if (message.includes('UNLOCK_WINDOW_OUT_OF_RANGE')) return 'A break-glass window is 1 to 240 minutes.';
  if (message.includes('UNLOCK_ALREADY_OPEN')) {
    return 'This set already has a request awaiting a decision, or a window still open.';
  }
  if (message.includes('UNLOCK_NOT_PENDING')) return 'That request has already been decided.';
  if (message.includes('UNLOCK_REQUEST_NOT_FOUND')) return 'Break-glass request not found.';
  if (message.includes('MARKS_NOT_LOCKED')) {
    return 'These marks were never signed off, so there is nothing to break the glass on.';
  }
  if (message.includes('break-glass request is append-only')) {
    return 'A break-glass request records what was asked, by whom and why. None of those is editable afterwards.';
  }
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}

/**
 * FR-I14. "0 of 40 scripts reviewed" is the one message the acceptance criteria
 * assert word for word, and fn_promote_ocr_marks() composes it from counts only
 * the database has — so it passes through untranslated, exactly as FR-I16's two
 * completeness sentences do. Everything else on this path is a named code,
 * because there is nothing in it the database knows and the screen does not.
 */
const OCR_PASS_THROUGH = [/^\d+ of \d+ scripts reviewed$/, /^max \d+$/, /^whole numbers only$/];

export function ocrReviewError(message: string): string {
  const line = message.split('\n')[0]?.trim() ?? message;
  if (OCR_PASS_THROUGH.some((p) => p.test(line))) return line;

  if (line === 'marks_locked') {
    return 'These marks were approved and signed off — a correction needs a break-glass unlock.';
  }
  if (message.includes('a machine mark needs a named teacher')) {
    return 'An OCR mark reaches a report card only through a teacher who confirmed it.';
  }
  if (message.includes('an OCR review action is append-only')) {
    return 'A confirmation is a signature. It is written once and it stays.';
  }
  if (message.includes('an OCR suggestion is append-only')) return 'What the machine read cannot be rewritten.';
  if (message.includes('an OCR batch is append-only')) return 'A batch is promoted once, or abandoned once.';
  if (message.includes('OCR_CANCEL_REASON_REQUIRED')) {
    return 'Say why in at least 10 characters — abandoning a scan is on the record.';
  }
  if (message.includes('OCR_JOB_ALREADY_OPEN')) return 'This paper already has a batch waiting for review.';
  if (message.includes('OCR_JOB_NOT_OPEN')) return 'That batch has already been promoted or abandoned.';
  if (message.includes('OCR_SUGGESTION_NOT_FOUND')) {
    return 'That question is not one this batch read — reload the grid.';
  }
  if (message.includes('OCR_ENROLMENT_MISMATCH')) {
    return 'Every scanned script must belong to a candidate in this section.';
  }
  if (message.includes('OCR_SUGGESTIONS_REQUIRED')) return 'A batch with nothing to review is not a batch.';
  if (message.includes('OCR_REVIEW_EMPTY')) return 'Nothing was selected to confirm.';
  if (message.includes('OCR_JOB_NOT_FOUND')) return 'That batch no longer exists.';
  if (message.includes('MARK_COMPONENT_NOT_CONFIGURED')) return 'That component is not part of this paper.';
  if (message.includes('SECTION_NOT_IN_EXAM_SUBJECT')) {
    return 'That section does not sit this paper — check the class and stream.';
  }
  if (message.includes('EXAM_SUBJECT_NOT_FOUND')) return 'This paper has no exam setup yet.';
  if (message.includes('FORBIDDEN')) return 'You do not teach this class subject.';
  return 'Could not complete that review.';
}
