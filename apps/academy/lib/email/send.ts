/**
 * Transactional email via Resend's HTTP API.
 *
 * Deliberately a `fetch` call rather than the `resend` SDK: the whole surface we
 * need is one POST, and this repo keeps its dependency count low on purpose.
 *
 * SECURITY: RESEND_API_KEY is read from the server environment and must never
 * be exposed to the browser. It is not a NEXT_PUBLIC_* var, so Next will not
 * inline it into client bundles; the guard below is the second line of defence
 * in case this module is ever imported from a client component by mistake.
 */

const RESEND_ENDPOINT = 'https://api.resend.com/emails';

export type SendResult =
  | { ok: true; id: string }
  | { ok: false; reason: 'not_configured' | 'rejected'; detail: string };

function assertServer() {
  if (typeof window !== 'undefined') {
    throw new Error('lib/email/send.ts was imported into client code — it holds a server secret.');
  }
}

export function emailConfigured() {
  assertServer();
  return Boolean(process.env.RESEND_API_KEY);
}

export async function sendEmail({
  to,
  subject,
  html,
  text,
}: {
  to: string;
  subject: string;
  html: string;
  text: string;
}): Promise<SendResult> {
  assertServer();

  const apiKey = process.env.RESEND_API_KEY;
  const from = process.env.EMAIL_FROM ?? 'Seena Academy <onboarding@resend.dev>';

  // Missing configuration is reported, never silently swallowed — a reset flow
  // that appears to succeed while sending nothing is worse than a clear failure.
  if (!apiKey) {
    return { ok: false, reason: 'not_configured', detail: 'RESEND_API_KEY is not set' };
  }

  let response: Response;
  try {
    response = await fetch(RESEND_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ from, to, subject, html, text }),
    });
  } catch (cause) {
    return { ok: false, reason: 'rejected', detail: `network error: ${String(cause)}` };
  }

  const payload = (await response.json().catch(() => ({}))) as { id?: string; message?: string };

  if (!response.ok) {
    return {
      ok: false,
      reason: 'rejected',
      detail: payload.message ?? `Resend returned HTTP ${response.status}`,
    };
  }

  return { ok: true, id: payload.id ?? 'unknown' };
}
