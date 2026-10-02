import { headers } from 'next/headers';

// Kicks a worker endpoint once for responsiveness; the scheduled caller is the
// real guarantee, so a failed nudge is ignored.
export async function nudgeWorker(path: string): Promise<void> {
  const secret = process.env.EXPORT_WORKER_SECRET;
  const host = (await headers()).get('host');
  if (!secret || !host) return;
  const proto = process.env.NODE_ENV === 'production' ? 'https' : 'http';
  void fetch(`${proto}://${host}${path}`, { method: 'POST', headers: { 'x-worker-secret': secret } }).catch(() => undefined);
}
