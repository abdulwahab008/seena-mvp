import { describe, expect, it, vi } from 'vitest';
import { dispatchOutbox, type OutboxMessage } from './dispatch';

const msg = (id: string, over: Partial<OutboxMessage> = {}): OutboxMessage => ({
  id, tenant_id: 't1', channel: 'sms', recipient_phone: '03001234567', recipient_email: null, subject: null, body: 'hi', attempts: 0, ...over,
});

describe('dispatchOutbox', () => {
  it('sends, retries transient failures, gives up after three tries and flags schools with no provider', async () => {
    const send = vi.fn(async (m: { deliveryId: string }) =>
      m.deliveryId === 'ok' ? { ok: true as const, providerMsgId: 'p1' } : { ok: false as const, transient: true, errorCode: 'HTTP_503', errorText: 'busy' },
    );
    const record = vi.fn(async () => {});
    const requeue = vi.fn(async () => {});
    const transportFor = vi.fn(async (tenant: string) => (tenant === 't1' ? { transport: { name: 'x', send }, providerId: 'prov' } : null));
    const summary = await dispatchOutbox({
      claim: async () => [msg('ok'), msg('busy'), msg('tired', { attempts: 2 }), msg('nogw', { tenant_id: 't2' })],
      transportFor,
      record,
      requeue,
    });
    expect(summary).toEqual({ claimed: 4, sent: 1, failed: 1, retrying: 1, noProvider: 1 });
    expect(requeue).toHaveBeenCalledWith('busy', 5);
    expect(transportFor).toHaveBeenCalledTimes(2);
    expect(record).toHaveBeenCalledWith('nogw', null, expect.objectContaining({ errorCode: 'NO_PROVIDER' }));
  });
});
