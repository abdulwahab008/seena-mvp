import { NextResponse } from 'next/server';
import { ZodError } from 'zod';
import { QuotaExceededError } from './quota';
import { RateLimitError } from './ratelimit';

/**
 * Centralized API error response. Maps known, safe-to-surface errors to clean
 * client messages and statuses; everything else is logged server-side and
 * returned as a generic message so we never leak DB/Zod/LLM internals.
 */
export function apiError(e: unknown): NextResponse {
  if (e instanceof QuotaExceededError) {
    return NextResponse.json({ error: e.message, quota: e.quota }, { status: 429 });
  }
  if (e instanceof RateLimitError) {
    return NextResponse.json(
      { error: e.message },
      { status: 429, headers: { 'Retry-After': String(e.retryAfter) } },
    );
  }
  if (e instanceof ZodError) {
    const msg = e.issues.map((i) => `${i.path.join('.') || 'body'}: ${i.message}`).join('; ');
    return NextResponse.json({ error: `Invalid request: ${msg}` }, { status: 400 });
  }
  if (e instanceof Error && e.message === 'UNAUTHENTICATED') {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 });
  }
  console.error('[api] unhandled error', e);
  return NextResponse.json({ error: 'Request failed.' }, { status: 400 });
}
