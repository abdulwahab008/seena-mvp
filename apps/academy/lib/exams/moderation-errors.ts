/**
 * FR-I15. The named errors fn_apply_moderation() / fn_reverse_moderation() raise,
 * as sentences. The cap refusal carries the cap value both in its message
 * ("MODERATION_CAP_EXCEEDED: 5" or "...: 5%") and in its DETAIL, and the screen
 * repeats the DETAIL: the controller must see what the limit is.
 */
export function moderationError(message: string, details?: string | null): string {
  const cap = /MODERATION_CAP_EXCEEDED: (\S+)/.exec(message);
  if (cap) return `The adjustment is above the cap. ${details ?? `The maximum is ${cap[1]}.`}`;
  if (message.includes('MARKS_APPROVED')) return `These marks are already approved. ${details ?? ''} Use the break-glass unlock to reopen them first.`.replace(/\s+/g, ' ').trim();
  if (message.includes('MODERATION_EXISTS')) return 'This section and subject were already moderated. Reverse that moderation before applying another.';
  if (message.includes('REASON_TOO_SHORT')) return details ?? 'The reason is too short.';
  if (message.includes('DELTA_REQUIRED')) return 'The adjustment cannot be zero.';
  if (message.includes('MODERATION_PRECISION')) return details ?? 'This campus records marks to a different precision.';
  if (message.includes('NO_MARKS_TO_MODERATE')) return details ?? 'No present candidate has a mark to moderate yet.';
  if (message.includes('MODERATION_ALREADY_REVERSED')) return 'That moderation has already been reversed.';
  if (message.includes('SECTION_SUBJECT_MISMATCH')) return 'That section does not sit this paper.';
  if (message.includes('COMPONENT_NOT_CONFIGURED')) return 'This paper has no theory component.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}
