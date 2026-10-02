import type { SupabaseClient } from '@supabase/supabase-js';
import type { Database } from './database.types';

/**
 * FR-A16. The `imp` claim the custom access token hook adds to a support
 * engineer's token while a session is live. A normally-issued token never
 * carries it, which is the whole reason the banner can be trusted: it is not
 * derived from a route, a cookie or a client flag, but from the same token the
 * database is reading when it decides what this request may see.
 *
 * `sub` is the impersonated user; the token's own `sub` remains the engineer,
 * so `by` and the session's auth.uid() are the same person throughout.
 */
export type ImpersonationClaim = {
  /** impersonation_session.id */
  sid: string;
  /** The impersonated app_user. */
  sub: string;
  /** The support engineer — the real human, and still the token's `sub`. */
  by: string;
  /** The session deadline, as an ISO timestamp. Never more than 60 minutes out. */
  exp: string;
};

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

export function parseImpersonationClaim(claims: unknown): ImpersonationClaim | null {
  if (!claims || typeof claims !== 'object') return null;
  const imp = (claims as Record<string, unknown>).imp;
  if (!imp || typeof imp !== 'object' || Array.isArray(imp)) return null;

  const { sid, sub, by, exp } = imp as Record<string, unknown>;
  if (!isNonEmptyString(sid) || !isNonEmptyString(sub) || !isNonEmptyString(by) || !isNonEmptyString(exp)) {
    return null;
  }
  return { sid, sub, by, exp };
}

/**
 * The role ceiling from chk_impersonation_role_ceiling, mirrored here so the
 * target picker cannot offer an account start_impersonation() would refuse.
 * Presentation only — the CHECK is what actually holds.
 */
const NON_IMPERSONATABLE_ROLES: ReadonlySet<string> = new Set([
  'super_admin',
  'owner',
  'parent',
  'student',
]);

export function isImpersonatable(role: string): boolean {
  return !NON_IMPERSONATABLE_ROLES.has(role);
}

/** app.tg_block_impersonated_write() — a money or results write inside a session. */
export function isImpersonationWriteBlocked(message: string): boolean {
  return message.includes('IMPERSONATION_WRITE_BLOCKED');
}

/**
 * app.assert_impersonation_live()'s PT401. The consent was withdrawn, it
 * expired, the 60-minute window closed, or somebody ended the session — and
 * because the check is a per-request lookup rather than a token property, this
 * arrives on the very next request, not at the next token refresh.
 */
export function isImpersonationSessionEnded(message: string): boolean {
  return message.includes('IMPERSONATION_SESSION_ENDED');
}

export const IMPERSONATION_WRITE_BLOCKED_MESSAGE =
  'Blocked: financial and result-publishing changes are never permitted while impersonating. The attempt has been recorded and the school has been alerted.';

/**
 * AC3's durable half. The BEFORE trigger raises and takes the whole
 * transaction with it, so the security_event has to be written by a second
 * one — this call. The block itself never depends on it: a caller who skips
 * the console is still refused, just without leaving its own security_event.
 */
export async function recordBlockedWrite(
  supabase: SupabaseClient<Database>,
  table: string,
  action: string,
): Promise<void> {
  await supabase.rpc('record_impersonation_block', { p_table: table, p_action: action });
}

export function consentError(message: string): string {
  if (message.includes('CONSENT_WINDOW_INVALID')) return 'Consent lasts between 1 and 24 hours.';
  if (message.includes('CONSENT_NOT_FOUND')) return 'That consent no longer exists.';
  if (message.includes('IMPERSONATION_ROLE_FORBIDDEN')) {
    return 'Owners, platform admins, parents and students can never be impersonated.';
  }
  if (message.includes('FORBIDDEN')) return 'Only the school’s Owner can grant or withdraw support access.';
  return 'Could not change support access.';
}

export function startImpersonationError(message: string): string {
  if (message.includes('IMPERSONATION_NOT_CONSENTED')) {
    return 'This school has not granted support access. Ask their Owner to grant it first.';
  }
  if (message.includes('CONSENT_REVOKED')) return 'The school withdrew support access.';
  if (message.includes('CONSENT_EXPIRED')) return 'The school’s support access has expired.';
  if (message.includes('IMPERSONATION_ALREADY_ACTIVE')) {
    return 'There is already a live session for you or for that user. End it first.';
  }
  if (message.includes('IMPERSONATION_ROLE_FORBIDDEN')) {
    return 'Owners, platform admins, parents and students can never be impersonated.';
  }
  if (message.includes('IMPERSONATION_SELF_FORBIDDEN')) return 'You cannot impersonate yourself.';
  if (message.includes('IMPERSONATION_TARGET_UNKNOWN')) return 'That user is not an active member of this school.';
  if (message.includes('IMPERSONATION_WINDOW_INVALID')) return 'A session lasts between 1 and 60 minutes.';
  if (message.includes('FORBIDDEN')) return 'Only platform support can impersonate.';
  return 'Could not start the session.';
}

/** mm:ss, floored at zero — a negative countdown reads as a bug, not as urgency. */
export function formatCountdown(msRemaining: number): string {
  const total = Math.max(0, Math.floor(msRemaining / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`;
}

const END_REASONS: Record<string, string> = {
  ended_by_support: 'Ended by support',
  ended_by_owner: 'Ended by the school',
  expired: 'Window expired',
  consent_revoked: 'Consent withdrawn',
  consent_expired: 'Consent expired',
};

export function endReasonLabel(reason: string | null): string {
  if (!reason) return 'Live';
  return END_REASONS[reason] ?? reason;
}
