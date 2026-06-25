import { redis } from './queue';

export class RateLimitError extends Error {
  retryAfter: number;
  constructor(retryAfter: number) {
    super('Too many requests. Please slow down.');
    this.name = 'RateLimitError';
    this.retryAfter = retryAfter;
  }
}

/**
 * Fixed-window per-key rate limit backed by Redis (the same instance BullMQ
 * uses, so no new dependency). Throws RateLimitError when the window budget is
 * exhausted. Keyed by caller (typically `${route}:${orgId}`) so limits are
 * per-org, not global.
 */
export async function rateLimit(key: string, limit: number, windowSec: number): Promise<void> {
  const r = redis();
  const window = Math.floor(Date.now() / 1000 / windowSec);
  const bucket = `rl:${key}:${window}`;
  const n = await r.incr(bucket);
  if (n === 1) await r.expire(bucket, windowSec);
  if (n > limit) {
    const ttl = await r.ttl(bucket);
    throw new RateLimitError(ttl > 0 ? ttl : windowSec);
  }
}
