'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type OutboxMessageRow = {
  id: string;
  tenant_id: string;
  campus_id: string;
  batch_id: string | null;
  recipient_type: 'parent' | 'guardian' | 'student' | 'staff' | 'custom';
  recipient_id: string | null;
  recipient_phone: string | null;
  recipient_email: string | null;
  channel: 'sms' | 'whatsapp' | 'email' | 'push';
  sender_id: string | null;
  subject: string | null;
  body: string;
  status: 'queued' | 'claimed' | 'sending' | 'delivered' | 'failed' | 'cancelled' | 'unknown';
  scheduled_at: string;
  claimed_at: string | null;
  claimed_by: string | null;
  idempotency_key: string | null;
  metadata: Record<string, unknown>;
  created_at: string;
  attempts?: MessageAttemptRow[];
};

export type MessageAttemptRow = {
  id: string;
  message_id: string;
  attempt_number: number;
  provider_id: string | null;
  provider_ref: string | null;
  status: 'sending' | 'sent' | 'delivered' | 'failed' | 'unknown' | 'timeout';
  error_code: string | null;
  error_message: string | null;
  raw_response: Record<string, unknown> | null;
  dispatched_at: string;
  completed_at: string | null;
  created_at: string;
};

export type OutboxStats = {
  queued: number;
  claimed: number;
  sending: number;
  delivered: number;
  failed: number;
  unknown: number;
  total: number;
};

export async function getOutboxMessages(params: {
  campusId?: string | null;
  status?: string | null;
  channel?: string | null;
  limit?: number;
}): Promise<OutboxMessageRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let query = (supabase as any)
    .from('message')
    .select(`
      *,
      attempts:message_attempt(*)
    `)
    .order('created_at', { ascending: false })
    .limit(params.limit || 50);

  if (params.campusId) {
    query = query.eq('campus_id', params.campusId);
  }
  if (params.status && params.status !== 'all') {
    query = query.eq('status', params.status);
  }
  if (params.channel && params.channel !== 'all') {
    query = query.eq('channel', params.channel);
  }

  const { data, error } = await query;
  if (error) {
    console.error('Failed to fetch outbox messages:', error);
    return [];
  }
  return data || [];
}

export async function getOutboxStats(campusId?: string | null): Promise<OutboxStats> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let query = (supabase as any).from('message').select('status');
  if (campusId) {
    query = query.eq('campus_id', campusId);
  }

  const { data } = await query;
  const stats: OutboxStats = {
    queued: 0,
    claimed: 0,
    sending: 0,
    delivered: 0,
    failed: 0,
    unknown: 0,
    total: 0,
  };

  if (!data) return stats;

  for (const row of data) {
    stats.total += 1;
    const s = row.status as keyof Omit<OutboxStats, 'total'>;
    if (s in stats) {
      stats[s] += 1;
    }
  }

  return stats;
}

export async function createOutboundMessage(input: {
  campusId: string;
  channel: 'sms' | 'whatsapp' | 'email' | 'push';
  recipientPhone?: string;
  recipientEmail?: string;
  recipientType?: 'parent' | 'guardian' | 'student' | 'staff' | 'custom';
  body: string;
  subject?: string;
  senderId?: string;
  idempotencyKey?: string;
}): Promise<{ success: boolean; error?: string; messageId?: string }> {
  try {
    const supabase = await supabaseServer();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: campus } = await (supabase as any)
      .from('campus')
      .select('tenant_id')
      .eq('id', input.campusId)
      .single();

    const tenantId = campus?.tenant_id;
    if (!tenantId) {
      return { success: false, error: 'Could not determine tenant for selected campus' };
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error } = await (supabase as any)
      .from('message')
      .insert({
        tenant_id: tenantId,
        campus_id: input.campusId,
        channel: input.channel,
        recipient_phone: input.recipientPhone || null,
        recipient_email: input.recipientEmail || null,
        recipient_type: input.recipientType || 'guardian',
        sender_id: input.senderId || 'SEENA',
        subject: input.subject || null,
        body: input.body,
        idempotency_key: input.idempotencyKey || `manual-${Date.now()}-${Math.random().toString(36).substring(2, 7)}`,
        status: 'queued',
      })
      .select('id')
      .single();

    if (error) {
      return { success: false, error: error.message };
    }

    revalidatePath('/communication/outbox');
    return { success: true, messageId: data.id };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function processOutboxBatch(
  workerId: string,
  limit: number = 10,
  channel?: 'sms' | 'whatsapp' | 'email' | 'push'
): Promise<{ success: boolean; claimedCount: number; error?: string }> {
  try {
    const supabase = await supabaseServer();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data, error } = await (supabase as any).rpc('claim_message_batch', {
      p_worker_id: workerId,
      p_limit: limit,
      p_channel: channel || null,
    });

    if (error) {
      return { success: false, claimedCount: 0, error: error.message };
    }

    revalidatePath('/communication/outbox');
    return { success: true, claimedCount: (data || []).length };
  } catch (err: unknown) {
    return { success: false, claimedCount: 0, error: err instanceof Error ? err.message : String(err) };
  }
}

export async function resolveUnknownOutboxAttempt(
  attemptId: string,
  status: 'sent' | 'delivered' | 'failed',
  providerRef: string
): Promise<{ success: boolean; error?: string }> {
  try {
    const supabase = await supabaseServer();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { error } = await (supabase as any).rpc('resolve_unknown_attempt', {
      p_attempt_id: attemptId,
      p_resolved_status: status,
      p_provider_ref: providerRef,
      p_raw_response: { resolved_manually: true, timestamp: new Date().toISOString() },
    });

    if (error) {
      return { success: false, error: error.message };
    }

    revalidatePath('/communication/outbox');
    return { success: true };
  } catch (err: unknown) {
    return { success: false, error: err instanceof Error ? err.message : String(err) };
  }
}
