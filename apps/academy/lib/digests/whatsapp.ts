import type { DigestMessage, DigestTransport, SendResult } from './transport';

/**
 * Meta WhatsApp Cloud API adapter for digest delivery (FR-S06).
 *
 * Only ever sends a TEMPLATE message: a free-form text message is not
 * representable here, so it cannot be attempted outside the 24-hour service
 * window by accident. The access token and phone number id are passed in by the
 * server worker (read from Supabase Vault via digest_provider_secret()); they are
 * never read from a NEXT_PUBLIC variable and never sent to the browser.
 *
 * Not exercised against Meta's live API in this repository (no credentials are
 * provisioned): the request/response shapes follow the documented Cloud API
 * contract and are covered by unit tests with an injected fetch.
 */

export type WhatsAppConfig = { accessToken: string; phoneNumberId: string; apiVersion?: string; baseUrl?: string };

const GRAPH = 'https://graph.facebook.com';

export function buildTemplatePayload(message: DigestMessage, expectedVariables?: number) {
  if (!message.templateName) throw new Error('WA_NO_TEMPLATE');
  if (!message.toMsisdn) throw new Error('WA_NO_RECIPIENT');
  if (expectedVariables !== undefined && message.variables.length !== expectedVariables) throw new Error('WA_VARIABLE_COUNT');
  return {
    messaging_product: 'whatsapp',
    to: message.toMsisdn.replace(/^\+/, ''),
    type: 'template',
    template: {
      name: message.templateName,
      language: { code: message.languageCode },
      components: [{ type: 'body', parameters: message.variables.map((text) => ({ type: 'text', text })) }],
    },
  };
}

// Meta error codes that mean "do not retry this on WhatsApp": the database turns
// these into an SMS fallback. Anything 5xx / network / rate-limit is transient.
export function classifyMetaError(status: number, body: unknown): Extract<SendResult, { ok: false }> {
  const err = (body as { error?: { code?: number; message?: string; error_data?: { details?: string } } } | null)?.error;
  const code = err?.code !== undefined ? String(err.code) : null;
  const text = err?.error_data?.details ?? err?.message ?? `WhatsApp responded with HTTP ${status}`;
  const transient = status >= 500 || status === 429 || code === '130429' || code === '131056' || code === '2' || code === '1';
  return { ok: false, transient, errorCode: code, errorText: text };
}

export class WhatsAppCloudTransport implements DigestTransport {
  readonly name = 'whatsapp-cloud';
  constructor(
    private readonly config: WhatsAppConfig,
    private readonly fetchImpl: typeof fetch = fetch,
  ) {}

  async send(message: DigestMessage): Promise<SendResult> {
    let payload;
    try {
      payload = buildTemplatePayload(message);
    } catch (e) {
      // our own pre-send guard: permanent, and it falls back to SMS in the database
      return { ok: false, transient: false, errorCode: e instanceof Error ? e.message : 'WA_INVALID', errorText: 'The WhatsApp template message could not be built' };
    }
    const url = `${this.config.baseUrl ?? GRAPH}/${this.config.apiVersion ?? 'v21.0'}/${this.config.phoneNumberId}/messages`;
    let res: Response;
    try {
      res = await this.fetchImpl(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${this.config.accessToken}`, 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
    } catch (e) {
      return { ok: false, transient: true, errorCode: null, errorText: e instanceof Error ? e.message : 'network error' };
    }
    const body: unknown = await res.json().catch(() => null);
    if (res.ok) {
      const id = (body as { messages?: { id?: string }[] } | null)?.messages?.[0]?.id;
      return id ? { ok: true, providerMsgId: id } : { ok: false, transient: true, errorCode: null, errorText: 'WhatsApp accepted the request but returned no message id' };
    }
    return classifyMetaError(res.status, body);
  }
}
