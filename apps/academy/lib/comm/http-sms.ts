import type { DigestMessage, DigestTransport, SendResult } from '@/lib/digests/transport';

/**
 * A generic HTTP SMS gateway. Pakistani branded-SMS providers almost all take
 * the same four things (API key, sender mask, number, text) as query or form
 * parameters on one URL and differ only in the parameter names, so the school
 * enters those names instead of us writing an adapter per company.
 */
export type HttpSmsConfig = {
  url: string;
  method: 'GET' | 'POST';
  keyParam: string;
  senderParam: string;
  toParam: string;
  textParam: string;
  /** Text the gateway puts in a successful reply (e.g. "OK" or "Success"); blank = any 2xx. */
  successMatch?: string;
  /** 92XXXXXXXXXX (default) or 03XXXXXXXXX. */
  numberFormat?: 'intl' | 'local';
};

export function formatPkMobile(raw: string, format: 'intl' | 'local' = 'intl'): string | null {
  const digits = raw.replace(/\D/g, '');
  const local = digits.startsWith('92') ? digits.slice(2) : digits.startsWith('0') ? digits.slice(1) : digits;
  if (!/^3\d{9}$/.test(local)) return null;
  return format === 'local' ? `0${local}` : `92${local}`;
}

export class HttpSmsTransport implements DigestTransport {
  readonly name = 'http-sms';
  constructor(
    private readonly config: HttpSmsConfig,
    private readonly apiKey: string,
    private readonly senderId: string,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async send(message: DigestMessage): Promise<SendResult> {
    const to = message.toMsisdn ? formatPkMobile(message.toMsisdn, this.config.numberFormat) : null;
    if (!to) return { ok: false, transient: false, errorCode: 'BAD_NUMBER', errorText: 'Not a Pakistani mobile number' };

    const params = new URLSearchParams({
      [this.config.keyParam]: this.apiKey,
      [this.config.senderParam]: this.senderId,
      [this.config.toParam]: to,
      [this.config.textParam]: message.body,
    });
    let res: Response;
    try {
      res =
        this.config.method === 'GET'
          ? await this.fetchImpl(`${this.config.url}${this.config.url.includes('?') ? '&' : '?'}${params}`, { method: 'GET' })
          : await this.fetchImpl(this.config.url, { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: params });
    } catch (e) {
      return { ok: false, transient: true, errorCode: null, errorText: e instanceof Error ? e.message : 'network error' };
    }
    const text = (await res.text().catch(() => '')).slice(0, 500);
    if (!res.ok) return { ok: false, transient: res.status >= 500 || res.status === 429, errorCode: `HTTP_${res.status}`, errorText: text || `Gateway responded with HTTP ${res.status}` };
    if (this.config.successMatch && !text.toLowerCase().includes(this.config.successMatch.toLowerCase())) {
      return { ok: false, transient: false, errorCode: 'GATEWAY_REJECTED', errorText: text || 'The gateway did not confirm the message' };
    }
    return { ok: true, providerMsgId: text.slice(0, 100) || `http-${message.deliveryId.slice(0, 8)}` };
  }
}
