import { headers } from 'next/headers';

// Nudge the message worker so what was just queued goes out within seconds;
// the request never waits for it. The scheduled run is the real guarantee.
export async function kickMessageWorker(): Promise<void> {
  const secret = process.env.EXPORT_WORKER_SECRET;
  const host = (await headers()).get('host');
  if (!secret || !host) return;
  const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
  void fetch(`${proto}://${host}/api/internal/messages`, { method: 'POST', headers: { 'x-worker-secret': secret } }).catch(() => undefined);
}
