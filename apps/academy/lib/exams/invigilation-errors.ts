/** FR-I10. Named errors from the invigilation RPCs, as sentences. */
const BLOCKED_REASON: Record<string, string> = {
  own_subject: 'teaches this subject to that class',
  on_leave: 'is on approved leave that day',
  excluded: 'is on the exclusion list for that day',
  overlapping_duty: 'already invigilates another paper at that time',
  max_duties: 'has reached the duty cap for the term',
};

export function blockedReasonText(code: string): string {
  return BLOCKED_REASON[code] ?? code;
}

export function invigilationError(message: string): string {
  const eligible = /STAFF_NOT_ELIGIBLE: (\w+)/.exec(message);
  if (eligible) return `That person cannot take this paper: they ${blockedReasonText(eligible[1]!)}.`;
  if (message.includes('STAFF_NOT_IN_POOL')) return 'That person is not an active staff member of this campus.';
  if (message.includes('SLOT_NOT_FOUND')) return 'Paper slot not found.';
  if (message.includes('DUTY_NOT_FOUND')) return 'Duty not found.';
  if (message.includes('DATESHEET_NOT_FOUND')) return 'Datesheet not found.';
  if (message.includes('EXAM_TERM_NOT_FOUND')) return 'Exam term not found.';
  if (message.includes('EXCLUSION_TARGET_INVALID')) return 'Choose either a date or a paper to exclude.';
  if (message.includes('EXCLUSION_NOT_FOUND')) return 'Exclusion not found.';
  if (message.includes('REASON_REQUIRED')) return 'Enter a reason.';
  if (message.includes('INVIGILATORS_INVALID')) return 'Invigilators per paper must be between 1 and 50.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}
