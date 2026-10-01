import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { parseForwardedIp } from '@/lib/request-ip';
import { hashIp, padToMinimum, renderVerifyPage, type VerifyResult } from '@/lib/certificates/verify-core';

/**
 * FR-T10: what a receiving school sees when it scans the QR on a certificate.
 *
 * Deliberately unauthenticated (see middleware PUBLIC_PREFIXES) and therefore
 * deliberately thin. Everything shown is decided by verify_certificate() in the
 * database, which masks the student before it leaves Postgres, rate limits per
 * address, logs every call and treats an unknown code exactly like a known one
 * until the very last step. This handler adds the two things the database
 * cannot: the real HTTP status, and a response-time floor so that a hit and a
 * miss cannot be told apart by timing.
 */

const MIN_RESPONSE_MS = 120;
const NOT_FOUND: VerifyResult = { http_status: 404, state: 'not_found', headline: 'No certificate found for this code' };

export async function GET(request: NextRequest, { params }: { params: Promise<{ token: string }> }) {
  const startedAt = Date.now();
  const { token } = await params;
  const ip = parseForwardedIp(request.headers.get('x-forwarded-for')) ?? parseForwardedIp(request.headers.get('x-real-ip'));

  let result: VerifyResult = NOT_FOUND;
  try {
    const { data, error } = await supabaseServiceRole().rpc('verify_certificate', {
      p_token: decodeURIComponent(token).slice(0, 80),
      p_ip_hash: hashIp(ip) ?? undefined,
      p_user_agent: request.headers.get('user-agent') ?? undefined,
    });
    if (!error && data) result = data as unknown as VerifyResult;
  } catch {
    // A failure must look like a miss, never like a hint that something is different about this code.
    result = NOT_FOUND;
  }

  await padToMinimum(startedAt, MIN_RESPONSE_MS);

  const headers: Record<string, string> = { 'cache-control': 'no-store', 'x-robots-tag': 'noindex' };
  if (result.http_status === 429) headers['retry-after'] = '60';

  if (request.headers.get('accept')?.includes('application/json')) {
    return NextResponse.json({ state: result.state, message: result.headline }, { status: result.http_status, headers });
  }
  return new NextResponse(renderVerifyPage(result), { status: result.http_status, headers: { ...headers, 'content-type': 'text/html; charset=utf-8' } });
}
