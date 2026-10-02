/**
 * FR-L11. The named errors submit_expense_voucher(), decide_expense_voucher()
 * and mark_expense_voucher_paid() raise, and the two trigger messages behind
 * them, turned into something a person can read.
 *
 * It lives here rather than in either actions.ts because a 'use server'
 * module may only export async functions, and both actions files need it.
 */
export function expenseError(message: string): string {
  if (message.includes('VOUCHER_NOT_APPROVED')) {
    return 'This voucher has not been approved yet, so it cannot be paid.';
  }
  if (message.includes('VOUCHER_NOT_PENDING')) return 'That voucher is no longer waiting for a decision.';
  if (message.includes('VOUCHER_NOT_FOUND')) return 'Voucher not found.';
  if (message.includes('APPROVER_RANK_INSUFFICIENT')) return 'This voucher is above your approval limit.';
  if (message.includes('REJECTION_REASON_TOO_SHORT')) {
    return 'A rejection has to say why, in at least 10 characters.';
  }
  if (message.includes('VOUCHER_DATE_INVALID')) return 'A voucher cannot be dated in the future.';
  if (message.includes('VOUCHER_PAYEE_REQUIRED')) return 'Name who is being paid.';
  if (message.includes('VOUCHER_AMOUNT_INVALID')) return 'Enter an amount above zero.';
  if (message.includes('EXPENSE_HEAD_NOT_FOUND')) return 'That expense head is not available.';
  if (message.includes('ATTACHMENT_PATH_MISMATCH')) return 'The bill does not belong to this campus.';
  if (message.includes('FILE_TOO_LARGE')) return 'Maximum file size 5 MB.';
  if (message.includes('UNSUPPORTED_FILE_TYPE')) return 'Only JPEG, PNG and PDF bills are accepted.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('expense voucher transition refused')) {
    return 'The database refused that change — a submitted voucher is fixed, and only an approved one can be paid.';
  }
  if (message.includes('expense approval trail is append-only')) {
    return 'The approval trail is append-only — nothing in it can be changed or removed.';
  }
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}
