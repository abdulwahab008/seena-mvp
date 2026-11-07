import { randomUUID } from 'node:crypto';
import { NextRequest, NextResponse } from 'next/server';
import { supabaseServiceRole } from '@/lib/supabase/server';
import { verifyWorkerSecret } from '@/lib/exports/worker-secret';
import { verifyCronSecret } from '@/lib/comm/cron-auth';
import { dispatchOutbox, type OutboxMessage } from '@/lib/comm/dispatch';
import { HttpSmsTransport, type HttpSmsConfig } from '@/lib/comm/http-sms';
import { ResendEmailTransport } from '@/lib/comm/email-transport';
import { emailConfigured } from '@/lib/email/send';
import { DevTransport } from '@/lib/digests/transport';

export const maxDuration = 120;

// The message worker: sends what is queued in the outbox through each school's
// SMS gateway (API key from Vault) or email. Called by the scheduler every
// minute with the worker secret. MESSAGE_TRANSPORT=dev sends everything to the
// dev transport instead, for local work and CI.
export async function POST(req: NextRequest) {
  if (!verifyWorkerSecret(req.headers.get('x-worker-secret'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return run();
}

// Vercel Cron (see vercel.json) sends a GET with the cron secret.
export async function GET(req: NextRequest) {
  if (!verifyCronSecret(req.headers.get('authorization'))) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  return run();
}

async function run() {
  const db = supabaseServiceRole();
  const dev = process.env.MESSAGE_TRANSPORT === 'dev' ? new DevTransport() : null;

  const summary = await dispatchOutbox({
    claim: async (limit) => {
      const { data, error } = await db.rpc('claim_message_batch', { p_worker_id: randomUUID(), p_limit: limit });
      if (error) throw new Error(`claim failed: ${error.message}`);
      const rows = (data ?? []) as Omit<OutboxMessage, 'attempts'>[];
      if (rows.length === 0) return [];
      const { data: attempts } = await db.from('message_attempt').select('message_id').in('message_id', rows.map((r) => r.id));
      const count = new Map<string, number>();
      for (const a of attempts ?? []) count.set(a.message_id, (count.get(a.message_id) ?? 0) + 1);
      return rows.map((r) => ({ ...r, attempts: count.get(r.id) ?? 0 }));
    },
    transportFor: async (tenantId, channel) => {
      if (dev) return { transport: dev, providerId: null };
      if (channel === 'email') return emailConfigured() ? { transport: new ResendEmailTransport(), providerId: null } : null;
      if (channel !== 'sms') return null;
      const { data } = await db.rpc('sms_gateway_for_dispatch', { p_tenant_id: tenantId }).maybeSingle();
      if (!data) return null;
      return { transport: new HttpSmsTransport(data.config as HttpSmsConfig, data.api_key, data.sender_id ?? ''), providerId: data.provider_id };
    },
    record: async (messageId, providerId, result) => {
      await db.rpc('record_message_attempt', {
        p_message_id: messageId,
        p_provider_id: providerId as string,
        p_status: result.ok ? 'sent' : 'failed',
        p_provider_ref: result.ok ? result.providerMsgId : undefined,
        p_error_code: result.ok ? undefined : (result.errorCode ?? undefined),
        p_error_message: result.ok ? undefined : result.errorText,
      });
    },
    requeue: async (messageId, delayMinutes) => {
      await db
        .from('message')
        .update({ status: 'queued', scheduled_at: new Date(Date.now() + delayMinutes * 60_000).toISOString(), claimed_at: null, claimed_by: null })
        .eq('id', messageId);
    },
  });
  return NextResponse.json(summary);
}
