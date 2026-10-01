/**
 * The seam between the digest queue (FR-S05/S06, in the database) and whatever
 * actually carries a message to a phone or inbox. The database decides what to
 * send, to whom, when, and what to do on failure; a transport only answers
 * "did the provider accept it, and if not, is it worth retrying?".
 */

export type DigestChannel = 'email' | 'sms' | 'whatsapp';

export type DigestMessage = {
  deliveryId: string;
  channel: DigestChannel;
  languageCode: string;
  toMsisdn: string | null;
  toEmail: string | null;
  title: string;
  /** Plain-text body (email, SMS). */
  body: string;
  /** Ordered template variables (WhatsApp). */
  variables: string[];
  /** Approved template name — WhatsApp only. Set by the database; never invented here. */
  templateName: string | null;
};

export type SendResult =
  | { ok: true; providerMsgId: string }
  | { ok: false; transient: boolean; errorCode: string | null; errorText: string };

export interface DigestTransport {
  readonly name: string;
  send(message: DigestMessage): Promise<SendResult>;
}

/**
 * Development / test transport: accepts everything and fabricates a provider id.
 * Two switches let tests and demos exercise the failure paths without a provider:
 * a body containing `[[fail-transient]]` fails retryably, `[[fail-permanent]]` does not.
 * It is NOT a stand-in for a real SMS aggregator or the Meta WhatsApp Cloud API — a
 * deployment must supply one through transportFor().
 */
export class DevTransport implements DigestTransport {
  readonly name = 'dev';
  async send(message: DigestMessage): Promise<SendResult> {
    if (message.body.includes('[[fail-transient]]')) return { ok: false, transient: true, errorCode: 'DEV_TRANSIENT', errorText: 'Simulated provider timeout' };
    if (message.body.includes('[[fail-permanent]]')) return { ok: false, transient: false, errorCode: 'DEV_PERMANENT', errorText: 'Simulated permanent rejection' };
    return { ok: true, providerMsgId: `dev-${message.channel}-${message.deliveryId.slice(0, 8)}` };
  }
}

export function transportFor(env: Record<string, string | undefined> = process.env): DigestTransport {
  // Real providers register here. Credentials come from the environment or the
  // database vault on the server only; none are read for the dev transport.
  if (env.DIGEST_TRANSPORT && env.DIGEST_TRANSPORT !== 'dev') {
    throw new Error(`Unknown DIGEST_TRANSPORT "${env.DIGEST_TRANSPORT}": only "dev" is built in; add a provider adapter implementing DigestTransport.`);
  }
  return new DevTransport();
}
