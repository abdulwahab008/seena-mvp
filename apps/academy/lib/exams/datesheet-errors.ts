/**
 * FR-I03 / FR-I04. Named errors raised by the datesheet RPCs, turned into
 * sentences. A student clash carries its GR numbers in the DETAIL, which
 * supabase-js surfaces as `details`; that text is shown verbatim because the
 * list of affected GR numbers IS the message the controller needs.
 */
export function datesheetError(message: string, details?: string | null): string {
  if (message.includes('DATESHEET_CLASH')) {
    return `Clash: ${details ?? 'some candidates sit both papers'}. The slot was not saved.`;
  }
  if (message.includes('HALL_DOUBLE_BOOKED')) return 'That hall is already booked for an overlapping time.';
  if (message.includes('DATESHEET_READONLY')) return 'This datesheet is published and read-only. Reopen it to make changes.';
  if (message.includes('DATESHEET_EXISTS')) return 'This term already has a datesheet.';
  if (message.includes('DATESHEET_NOT_FOUND')) return 'Datesheet not found.';
  if (message.includes('EXAM_SUBJECT_NOT_IN_TERM')) return 'That paper does not belong to this datesheet\'s term.';
  if (message.includes('HALL_NOT_FOUND')) return 'That hall is not available.';
  if (message.includes('HALL_SIZE_INVALID')) return 'A hall needs between 1 and 100 rows and seats per row.';
  if (message.includes('SLOT_TIME_INVALID')) return 'The paper must end after it starts.';
  if (message.includes('INVIGILATORS_INVALID')) return 'Invigilators per slot must be between 1 and 50.';
  if (message.includes('SETTINGS_INVALID')) return 'One of the settings is out of range.';
  if (message.includes('DATESHEET_HAS_CLASHES')) return `The datesheet still has clashing papers and cannot be published${details ? `: ${details}` : '.'}`;
  if (message.includes('DATESHEET_EMPTY')) return 'A datesheet with no papers cannot be published.';
  if (message.includes('DATESHEET_NOT_PUBLISHED')) return 'Only a published datesheet can be reopened for revision.';
  if (message.includes('DATESHEET_NOT_DRAFT')) return 'This datesheet is already published.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}
