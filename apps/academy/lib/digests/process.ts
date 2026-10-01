import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import type { Database } from '@/lib/database.types';
import type { DigestMessage, DigestTransport } from './transport';

type Db = SupabaseClient<Database>;

const claimedSchema = z.object({
  delivery_id: z.string().uuid(),
  channel: z.enum(['email', 'sms', 'whatsapp']),
  language_code: z.string(),
  to_msisdn: z.string().nullable(),
  to_email: z.string().nullable(),
  title: z.string(),
  body: z.string().nullable(),
  variables: z.array(z.string()).nullable(),
  template_name: z.string().nullable().optional(),
});

export function toMessage(row: z.infer<typeof claimedSchema>): DigestMessage {
  return {
    deliveryId: row.delivery_id,
    channel: row.channel,
    languageCode: row.language_code,
    toMsisdn: row.to_msisdn,
    toEmail: row.to_email,
    title: row.title,
    body: row.body ?? '',
    variables: row.variables ?? [],
    templateName: row.template_name ?? null,
  };
}

// One worker pass: run the dispatcher (idempotent, a safety net when pg_cron is
// absent), claim due attempts, hand each to the transport, report the outcome.
// The database owns retry and fallback; this loop only reports what happened.
export async function processDigestDeliveries(db: Db, transport: DigestTransport, limit = 25): Promise<{ dispatched: number; sent: number; failed: number }> {
  const { data: dispatched } = await db.rpc('dispatch_due_digests');
  const { data: claimed } = await db.rpc('claim_digest_deliveries', { p_limit: limit });
  let sent = 0;
  let failed = 0;
  for (const raw of claimed ?? []) {
    const row = claimedSchema.parse(raw);
    const result = await transport.send(toMessage(row)).catch((e: unknown) => ({ ok: false as const, transient: true, errorCode: 'TRANSPORT_EXCEPTION', errorText: e instanceof Error ? e.message : 'transport error' }));
    await db.rpc('record_digest_attempt_result', {
      p_delivery_id: row.delivery_id,
      p_ok: result.ok,
      p_provider_msg_id: result.ok ? result.providerMsgId : undefined,
      p_error: result.ok ? undefined : result.errorText,
      p_transient: result.ok ? false : result.transient,
      p_error_code: result.ok ? undefined : (result.errorCode ?? undefined),
    });
    if (result.ok) sent++;
    else failed++;
  }
  return { dispatched: dispatched ?? 0, sent, failed };
}
