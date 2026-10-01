import { describe, expect, it, vi } from 'vitest';
import { processDigestDeliveries, toMessage } from './process';
import { DevTransport, transportFor, type DigestTransport } from './transport';

const row = (over: Record<string, unknown> = {}) => ({
  delivery_id: '11111111-1111-4111-8111-111111111111',
  channel: 'sms',
  language_code: 'en',
  to_msisdn: '+923001112233',
  to_email: null,
  title: 'Group daily summary',
  body: 'collected PKR 1,800,000',
  variables: ['01 Oct 2026', '1,800,000'],
  template_name: null,
  ...over,
});

function fakeDb(claimed: unknown[]) {
  const calls: { fn: string; args: Record<string, unknown> | undefined }[] = [];
  const rpc = vi.fn(async (fn: string, args?: Record<string, unknown>) => {
    calls.push({ fn, args });
    if (fn === 'dispatch_due_digests') return { data: 2, error: null };
    if (fn === 'claim_digest_deliveries') return { data: claimed, error: null };
    return { data: null, error: null };
  });
  return { db: { rpc } as never, calls };
}

describe('processDigestDeliveries', () => {
  it('reports provider ids for accepted messages', async () => {
    const { db, calls } = fakeDb([row()]);
    const out = await processDigestDeliveries(db, new DevTransport());
    expect(out).toEqual({ dispatched: 2, sent: 1, failed: 0 });
    const report = calls.find((c) => c.fn === 'record_digest_attempt_result')!;
    expect(report.args).toMatchObject({ p_ok: true, p_transient: false });
    expect(String(report.args!.p_provider_msg_id)).toMatch(/^dev-sms-/);
  });

  it('reports transient and permanent failures with their text and code', async () => {
    const { db, calls } = fakeDb([row({ body: '[[fail-transient]]' }), row({ body: '[[fail-permanent]]' })]);
    const out = await processDigestDeliveries(db, new DevTransport());
    expect(out.failed).toBe(2);
    const reports = calls.filter((c) => c.fn === 'record_digest_attempt_result').map((c) => c.args);
    expect(reports[0]).toMatchObject({ p_ok: false, p_transient: true, p_error: 'Simulated provider timeout', p_error_code: 'DEV_TRANSIENT' });
    expect(reports[1]).toMatchObject({ p_ok: false, p_transient: false, p_error_code: 'DEV_PERMANENT' });
  });

  it('treats a throwing transport as a retryable failure instead of losing the attempt', async () => {
    const boom: DigestTransport = { name: 'boom', send: async () => { throw new Error('socket hang up'); } };
    const { db, calls } = fakeDb([row()]);
    await processDigestDeliveries(db, boom);
    expect(calls.find((c) => c.fn === 'record_digest_attempt_result')!.args).toMatchObject({ p_ok: false, p_transient: true, p_error: 'socket hang up' });
  });
});

describe('toMessage / transportFor', () => {
  it('maps the claimed row and defaults missing variables', () => {
    const m = toMessage({ ...row(), channel: 'whatsapp', variables: null, body: null, template_name: 'daily_summary_v1' } as never);
    expect(m).toMatchObject({ channel: 'whatsapp', variables: [], body: '', templateName: 'daily_summary_v1' });
  });
  it('refuses an unknown transport rather than silently using the dev one', () => {
    expect(() => transportFor({ DIGEST_TRANSPORT: 'carrier-pigeon' })).toThrow(/Unknown DIGEST_TRANSPORT/);
    expect(transportFor({}).name).toBe('dev');
  });
});
