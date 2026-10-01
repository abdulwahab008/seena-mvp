/** FR-J13. The named errors the transcript RPCs raise, as a person reads them. */
export function transcriptError(message: string): string {
  if (message.includes('PURPOSE_REQUIRED')) return 'Say what the transcript is for.';
  if (message.includes('NO_HISTORY')) return 'This student has no enrolment on record, so there is nothing to put on a transcript.';
  if (message.includes('STUDENT_NOT_FOUND')) return 'Student not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to issue a transcript for this student.';
  return 'Could not issue the transcript.';
}
