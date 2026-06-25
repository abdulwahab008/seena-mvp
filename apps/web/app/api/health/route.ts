import { NextResponse } from 'next/server';
import { sql } from 'drizzle-orm';
import { db } from '@/lib/db';
import { redis } from '@/lib/queue';

// Public liveness/readiness probe — DB + Redis reachability. No auth (not in the
// protected matcher) so external monitors and the worker host can hit it.
export const dynamic = 'force-dynamic';

export async function GET() {
  const checks: { db: 'ok' | 'fail'; redis: 'ok' | 'fail' } = { db: 'fail', redis: 'fail' };
  try {
    await db.execute(sql`select 1`);
    checks.db = 'ok';
  } catch {
    /* reported below */
  }
  try {
    await redis().ping();
    checks.redis = 'ok';
  } catch {
    /* reported below */
  }
  const ok = checks.db === 'ok' && checks.redis === 'ok';
  return NextResponse.json({ ok, ...checks }, { status: ok ? 200 : 503 });
}
