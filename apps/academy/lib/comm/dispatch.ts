import type { DigestTransport, SendResult } from '@/lib/digests/transport';

export type OutboxMessage = {
  id: string;
  tenant_id: string;
  channel: 'sms' | 'whatsapp' | 'email' | 'push';
  recipient_phone: string | null;
  recipient_email: string | null;
  subject: string | null;
  body: string;
  attempts: number;
};

export type Resolved = { transport: DigestTransport; providerId: string | null } | null;

export type DispatchDeps = {
  claim: (limit: number) => Promise<OutboxMessage[]>;
  /** The school's transport for a channel, or null when none is set up. */
  transportFor: (tenantId: string, channel: OutboxMessage['channel']) => Promise<Resolved>;
  record: (messageId: string, providerId: string | null, result: SendResult | { ok: false; transient: false; errorCode: string; errorText: string }) => Promise<void>;
  /** Put a transiently failed message back in the queue for a later try. */
  requeue: (messageId: string, delayMinutes: number) => Promise<void>;
};

export const MAX_ATTEMPTS = 3;

// Claims a batch from the outbox and sends each message. The database decides
// what is due and to whom (scheduling, quiet hours, opt-outs, fallback chains);
// this only carries it to the provider and records what the provider said.
export async function dispatchOutbox(deps: DispatchDeps, limit = 100) {
  const messages = await deps.claim(limit);
  const summary = { claimed: messages.length, sent: 0, failed: 0, retrying: 0, noProvider: 0 };
  const cache = new Map<string, Resolved>();

  for (const m of messages) {
    const key = `${m.tenant_id}:${m.channel}`;
    if (!cache.has(key)) cache.set(key, await deps.transportFor(m.tenant_id, m.channel));
    const resolved = cache.get(key)!;
    if (!resolved) {
      await deps.record(m.id, null, { ok: false, transient: false, errorCode: 'NO_PROVIDER', errorText: `No ${m.channel} provider is set up for this school` });
      summary.noProvider++;
      continue;
    }
    const result = await resolved.transport.send({
      deliveryId: m.id,
      channel: m.channel === 'push' ? 'sms' : m.channel,
      languageCode: 'en',
      toMsisdn: m.recipient_phone,
      toEmail: m.recipient_email,
      title: m.subject ?? '',
      body: m.body,
      variables: [],
      templateName: null,
    });
    await deps.record(m.id, resolved.providerId, result);
    if (result.ok) summary.sent++;
    else if (result.transient && m.attempts + 1 < MAX_ATTEMPTS) {
      await deps.requeue(m.id, 5 * (m.attempts + 1));
      summary.retrying++;
    } else summary.failed++;
  }
  return summary;
}
