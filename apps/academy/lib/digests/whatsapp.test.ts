import { describe, expect, it, vi } from 'vitest';
import { buildTemplatePayload, classifyMetaError, WhatsAppCloudTransport } from './whatsapp';
import { CompositeTransport, DevTransport, type DigestMessage } from './transport';

const msg = (over: Partial<DigestMessage> = {}): DigestMessage => ({
  deliveryId: 'd1d1d1d1-0000-4000-8000-000000000000',
  channel: 'whatsapp',
  languageCode: 'en',
  toMsisdn: '+923001112233',
  toEmail: null,
  title: 'Group daily summary',
  body: 'ignored for whatsapp',
  variables: ['01 Oct 2026', '1,800,000', '900,000', '90.0%', '1,000'],
  templateName: 'daily_summary_v1',
  ...over,
});

describe('WhatsApp template payload', () => {
  it('is a template message carrying exactly the five variables, formatted as given', () => {
    const p = buildTemplatePayload(msg(), 5);
    expect(p.type).toBe('template');
    expect(p.template.name).toBe('daily_summary_v1');
    expect(p.template.components[0]!.parameters).toHaveLength(5);
    expect(p.template.components[0]!.parameters[1]).toEqual({ type: 'text', text: '1,800,000' });
    expect(JSON.stringify(p)).not.toMatch(/1\.8M|"1800000"/);
    expect(p.to).toBe('923001112233');
  });
  it('refuses to build a free-form message: no template means no WhatsApp send', () => {
    expect(() => buildTemplatePayload(msg({ templateName: null }))).toThrow('WA_NO_TEMPLATE');
  });
  it('refuses a variable count different from the approved template', () => {
    expect(() => buildTemplatePayload(msg({ variables: ['a', 'b'] }), 5)).toThrow('WA_VARIABLE_COUNT');
  });
});

describe('WhatsAppCloudTransport', () => {
  const cfg = { accessToken: 'test-token', phoneNumberId: '1234' };
  it('posts to the messages endpoint with a bearer token and returns the wamid', async () => {
    const fetchMock = vi.fn(async () => new Response(JSON.stringify({ messages: [{ id: 'wamid.ABC' }] }), { status: 200 }));
    const t = new WhatsAppCloudTransport(cfg, fetchMock as never);
    const r = await t.send(msg());
    expect(r).toEqual({ ok: true, providerMsgId: 'wamid.ABC' });
    const [url, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toContain('/1234/messages');
    expect((init.headers as Record<string, string>).Authorization).toBe('Bearer test-token');
    expect(JSON.parse(init.body as string).type).toBe('template');
  });
  it('reports a re-engagement refusal as permanent with its Meta code (so SMS fallback triggers)', async () => {
    const t = new WhatsAppCloudTransport(cfg, (async () => new Response(JSON.stringify({ error: { code: 131047, message: 'Re-engagement message' } }), { status: 400 })) as never);
    expect(await t.send(msg())).toEqual({ ok: false, transient: false, errorCode: '131047', errorText: 'Re-engagement message' });
  });
  it('treats 5xx and network failures as transient', async () => {
    expect(classifyMetaError(503, null).transient).toBe(true);
    const t = new WhatsAppCloudTransport(cfg, (async () => { throw new Error('ECONNRESET'); }) as never);
    expect(await t.send(msg())).toMatchObject({ ok: false, transient: true, errorText: 'ECONNRESET' });
  });
  it('never calls the network when the template is missing', async () => {
    const fetchMock = vi.fn();
    const t = new WhatsAppCloudTransport(cfg, fetchMock as never);
    const r = await t.send(msg({ templateName: null }));
    expect(r).toMatchObject({ ok: false, transient: false, errorCode: 'WA_NO_TEMPLATE' });
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

describe('CompositeTransport', () => {
  it('routes WhatsApp to the cloud transport and everything else to the fallback', async () => {
    const wa = { name: 'wa', send: vi.fn(async () => ({ ok: true as const, providerMsgId: 'wamid.1' })) };
    const c = new CompositeTransport({ whatsapp: wa }, new DevTransport());
    expect((await c.send(msg())).ok).toBe(true);
    expect(wa.send).toHaveBeenCalledOnce();
    const sms = await c.send(msg({ channel: 'sms', templateName: null }));
    expect(sms).toMatchObject({ ok: true });
    expect(wa.send).toHaveBeenCalledOnce();
  });
});
