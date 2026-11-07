import { describe, expect, it, vi } from 'vitest';
import { HttpSmsTransport, formatPkMobile, type HttpSmsConfig } from './http-sms';

const config: HttpSmsConfig = { url: 'https://sms.example.pk/api/send', method: 'GET', keyParam: 'api_key', senderParam: 'mask', toParam: 'to', textParam: 'msg', successMatch: 'OK' };
const message = { deliveryId: '12345678-aaaa', channel: 'sms' as const, languageCode: 'en', toMsisdn: '+92 300 1234567', toEmail: null, title: '', body: 'Fee due', variables: [], templateName: null };

describe('formatPkMobile', () => {
  it('normalises Pakistani mobiles and rejects anything else', () => {
    expect(formatPkMobile('0300-1234567')).toBe('923001234567');
    expect(formatPkMobile('+923001234567', 'local')).toBe('03001234567');
    expect(formatPkMobile('042-35761234')).toBeNull();
  });
});

describe('HttpSmsTransport', () => {
  it('sends the configured parameters and accepts a confirmed reply', async () => {
    const fetchImpl = vi.fn(async () => new Response('OK:msg-991', { status: 200 }));
    const r = await new HttpSmsTransport(config, 'secret', 'SEENA', fetchImpl as unknown as typeof fetch).send(message);
    expect(r).toEqual({ ok: true, providerMsgId: 'OK:msg-991' });
    const url = new URL((fetchImpl.mock.calls[0] as unknown as [string])[0]);
    expect(Object.fromEntries(url.searchParams)).toEqual({ api_key: 'secret', mask: 'SEENA', to: '923001234567', msg: 'Fee due' });
  });

  it('treats a reply without the success text as a permanent rejection and 5xx as retryable', async () => {
    const rejected = await new HttpSmsTransport(config, 'k', 'S', (async () => new Response('Invalid mask', { status: 200 })) as unknown as typeof fetch).send(message);
    expect(rejected).toMatchObject({ ok: false, transient: false, errorCode: 'GATEWAY_REJECTED' });
    const down = await new HttpSmsTransport(config, 'k', 'S', (async () => new Response('busy', { status: 503 })) as unknown as typeof fetch).send(message);
    expect(down).toMatchObject({ ok: false, transient: true, errorCode: 'HTTP_503' });
  });

  it('refuses a landline before calling the gateway', async () => {
    const fetchImpl = vi.fn();
    const r = await new HttpSmsTransport(config, 'k', 'S', fetchImpl as unknown as typeof fetch).send({ ...message, toMsisdn: '04235761234' });
    expect(r).toMatchObject({ ok: false, errorCode: 'BAD_NUMBER' });
    expect(fetchImpl).not.toHaveBeenCalled();
  });
});
