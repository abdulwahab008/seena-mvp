import { createHash } from 'node:crypto';

/**
 * FR-T10: the pure parts of public certificate verification.
 *
 * Everything the unauthenticated endpoint puts on screen comes out of
 * verify_certificate() already masked in the database; this module only
 * decides how that is worded and coloured, escapes it, and pads the response
 * so that finding a certificate takes as long as not finding one.
 */

export type VerifyState = 'valid' | 'cancelled' | 'not_found' | 'rate_limited';

export type VerifyResult = {
  http_status: 200 | 404 | 429;
  state: VerifyState;
  headline: string;
};

/** A QR must be decodable by anyone, so it carries a random token and nothing about the student. */
export function buildVerifyUrl(origin: string, token: string): string {
  return `${origin.replace(/\/+$/, '')}/verify/${encodeURIComponent(token)}`;
}

/** The token alphabet the database generates (base64url without padding). Anything else cannot be a certificate. */
export function isPlausibleToken(token: string): boolean {
  return /^[A-Za-z0-9_-]{16,64}$/.test(token);
}

/** One-way, so the log can show that one address hammered the endpoint without keeping the address. */
export function hashIp(ip: string | null): string | null {
  if (!ip) return null;
  return createHash('sha256').update(`cert-verify:${ip}`).digest('hex');
}

export function hashToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

/**
 * Hit and miss must be indistinguishable by timing. The database does the same
 * work on both paths; this adds a floor so that what differs (a row fetched or
 * not) disappears into it. Resolves after at least `minMs` since `startedAt`.
 */
export async function padToMinimum(startedAt: number, minMs: number, now: () => number = Date.now, sleep: (ms: number) => Promise<void> = (ms) => new Promise((r) => setTimeout(r, ms))): Promise<void> {
  const remaining = minMs - (now() - startedAt);
  if (remaining > 0) await sleep(remaining);
}

const escapeHtml = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

const COLOUR: Record<VerifyState, { fg: string; bg: string }> = {
  valid: { fg: '#14532d', bg: '#dcfce7' },
  cancelled: { fg: '#991b1b', bg: '#fee2e2' },
  not_found: { fg: '#334155', bg: '#f1f5f9' },
  rate_limited: { fg: '#92400e', bg: '#fef3c7' },
};

/** The whole page. Deliberately minimal: the headline, and nothing else about anyone. */
export function renderVerifyPage(result: VerifyResult): string {
  const c = COLOUR[result.state];
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><title>Certificate verification</title></head>
<body style="font-family:system-ui,sans-serif;margin:0;padding:24px;background:#fff">
<main style="max-width:560px;margin:10vh auto 0">
<h1 style="font-size:14px;font-weight:600;color:#475569;margin:0 0 12px">Certificate verification</h1>
<p data-testid="verify-result" data-state="${result.state}" style="font-size:20px;line-height:1.4;font-weight:600;color:${c.fg};background:${c.bg};padding:16px;border-radius:8px;margin:0">${escapeHtml(result.headline)}</p>
</main></body></html>`;
}
