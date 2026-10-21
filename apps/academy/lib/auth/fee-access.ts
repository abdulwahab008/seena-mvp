/**
 * Who may use the fees area.
 *
 * Fee data (every family's challans, ledger, payments and receipts, the fee structure and the
 * concession awards) is for the people who handle fees: super admin, owner, principal and
 * accountant. The database enforces this (app.fn_fee_staff(), see migration
 * 20260806001000_fee_data_finance_roles.sql); this module is the same list for the app, so a
 * class teacher who types /fees is sent home and never sees a Fees section in the sidebar
 * instead of a page full of empty tables.
 *
 * The admissions officer is the one other role with a fees page: they request concession awards
 * and detect sibling groups as part of admissions, so those two pages stay open to them.
 *
 * The role is read from the signed token (the same claim the database policies read), never from
 * a cookie or a query string.
 */

export const FEE_STAFF_ROLES = ['super_admin', 'owner', 'principal', 'accountant'] as const;

/** Roles that can post a payment at the cash counter. */
export const FEE_COLLECTOR_ROLES = ['super_admin', 'owner', 'accountant'] as const;

/** The fees pages an admissions officer may open, because their admissions work uses them. */
export const ADMISSIONS_FEE_PATHS = ['/fees/concessions', '/fees/sibling-discounts'] as const;

/** Where a session without access lands when it wanders into a fees URL. */
export const FEES_DENIED_HOME = '/dashboard';

export function hasFeeAccess(role: unknown): boolean {
  return typeof role === 'string' && (FEE_STAFF_ROLES as readonly string[]).includes(role);
}

export function canCollectFees(role: unknown): boolean {
  return typeof role === 'string' && (FEE_COLLECTOR_ROLES as readonly string[]).includes(role);
}

/** Roles that see the concession awards of a student (the fee staff and the admissions officer). */
export function canSeeConcessionAwards(role: unknown): boolean {
  return hasFeeAccess(role) || role === 'admissions_officer';
}

/** Whether `role` may open `pathname`, a path under /fees (a query string is ignored). */
export function canOpenFeesPath(role: unknown, pathname: string): boolean {
  if (hasFeeAccess(role)) return true;
  if (role !== 'admissions_officer') return false;
  const path = pathname.split('?')[0] ?? '';
  return ADMISSIONS_FEE_PATHS.some((allowed) => path === allowed || path.startsWith(`${allowed}/`));
}
