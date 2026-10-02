'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type CommChannel = 'sms' | 'whatsapp' | 'email' | 'push';

export type CommChannelChainRow = {
  id: string;
  tenant_id: string;
  message_class: string;
  ordered_channels: CommChannel[];
  wait_seconds: Record<string, number>;
  is_active: boolean;
  description: string | null;
  created_at: string;
  updated_at: string;
};

export type CommOptOutRow = {
  id: string;
  tenant_id: string;
  recipient_phone: string | null;
  recipient_email: string | null;
  channel: CommChannel;
  reason: string | null;
  opted_out_at: string;
};

export type MessageCostLedgerRow = {
  id: string;
  tenant_id: string;
  campus_id: string | null;
  message_id: string;
  attempt_id: string | null;
  channel: CommChannel;
  currency: string;
  cost_paisa: number;
  rate_per_unit: number;
  units: number;
  status: string;
  created_at: string;
};

export type FallbackMessageReportRow = {
  id: string;
  recipient_phone: string | null;
  recipient_type: string;
  body: string;
  message_class: string;
  channel: CommChannel;
  status: string;
  final_status: string | null;
  created_at: string;
  attempts: {
    id: string;
    attempt_number: number;
    channel: CommChannel;
    status: string;
    skip_reason: string | null;
    error_code: string | null;
    dispatched_at: string;
    completed_at: string | null;
  }[];
  costs: MessageCostLedgerRow[];
};

/**
 * Fetch all fallback chain rules for the active tenant.
 */
export async function getChannelChains(): Promise<CommChannelChainRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client
    .from('comm_channel_chain')
    .select('*')
    .order('message_class', { ascending: true });

  if (error) {
    console.error('getChannelChains error:', error);
    return [];
  }

  return (data || []) as CommChannelChainRow[];
}

/**
 * Create or update a fallback chain rule.
 */
export async function saveChannelChain(input: {
  id?: string;
  message_class: string;
  ordered_channels: CommChannel[];
  wait_seconds: Record<string, number>;
  description?: string;
  is_active?: boolean;
}): Promise<{ success: boolean; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { success: false, error: 'Unauthorized: Authentication required.' };
  }

  // Resolve active tenant
  const { data: userData } = await client
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  const tenantId = userData?.tenant_id || user.user_metadata?.tenant_id;
  if (!tenantId) {
    return { success: false, error: 'Active tenant not found.' };
  }

  if (!input.ordered_channels || input.ordered_channels.length === 0) {
    return { success: false, error: 'At least one channel must be in the fallback chain.' };
  }

  const payload = {
    tenant_id: tenantId,
    message_class: input.message_class.trim().toLowerCase(),
    ordered_channels: input.ordered_channels,
    wait_seconds: input.wait_seconds || { whatsapp: 900, sms: 600, email: 3600, push: 300 },
    description: input.description || null,
    is_active: input.is_active !== undefined ? input.is_active : true,
    updated_at: new Date().toISOString(),
  };

  const { error } = await client
    .from('comm_channel_chain')
    .upsert(payload, { onConflict: 'tenant_id,message_class' });

  if (error) {
    console.error('saveChannelChain error:', error);
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/fallback-chains');
  revalidatePath('/communication/outbox');
  return { success: true };
}

/**
 * Fetch all recipient opt-out records for the active tenant.
 */
export async function getOptOuts(): Promise<CommOptOutRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client
    .from('comm_opt_out')
    .select('*')
    .order('opted_out_at', { ascending: false });

  if (error) {
    console.error('getOptOuts error:', error);
    return [];
  }

  return (data || []) as CommOptOutRow[];
}

/**
 * Register a recipient channel opt-out.
 */
export async function saveOptOut(input: {
  recipient_phone?: string;
  recipient_email?: string;
  channel: CommChannel;
  reason?: string;
}): Promise<{ success: boolean; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    return { success: false, error: 'Unauthorized.' };
  }

  const { data: userData } = await client
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  const tenantId = userData?.tenant_id || user.user_metadata?.tenant_id;
  if (!tenantId) {
    return { success: false, error: 'Tenant context missing.' };
  }

  const { error } = await client.from('comm_opt_out').insert({
    tenant_id: tenantId,
    recipient_phone: input.recipient_phone?.trim() || null,
    recipient_email: input.recipient_email?.trim() || null,
    channel: input.channel,
    reason: input.reason || 'Admin manual opt-out',
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/fallback-chains');
  return { success: true };
}

/**
 * Remove an opt-out restriction.
 */
export async function removeOptOut(id: string): Promise<{ success: boolean; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { error } = await client.from('comm_opt_out').delete().eq('id', id);

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/fallback-chains');
  return { success: true };
}

/**
 * Trigger the timeout window scanner to escalate any pending in-flight messages.
 */
export async function triggerTimeoutScan(): Promise<{
  success: boolean;
  escalated_count: number;
  results: any[];
  error?: string;
}> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client.rpc('escalate_timed_out_attempts');

  if (error) {
    console.error('triggerTimeoutScan error:', error);
    return { success: false, escalated_count: 0, results: [], error: error.message };
  }

  revalidatePath('/communication/fallback-chains');
  revalidatePath('/communication/outbox');
  return { success: true, escalated_count: (data || []).length, results: data || [] };
}

/**
 * Simulate an incoming aggregator delivery receipt webhook.
 */
export async function simulateReceiptWebhook(input: {
  attempt_id: string;
  receipt_status: 'delivered' | 'undelivered' | 'sent' | 'failed';
  error_code?: string;
}): Promise<{ success: boolean; new_status?: string; error?: string }> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client.rpc('apply_receipt', {
    p_attempt_id: input.attempt_id,
    p_receipt_status: input.receipt_status,
    p_error_code: input.error_code || null,
    p_raw_response: { simulated_at: new Date().toISOString(), source: 'test_console' },
  });

  if (error) {
    console.error('simulateReceiptWebhook error:', error);
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/fallback-chains');
  revalidatePath('/communication/outbox');
  return { success: true, new_status: data };
}

/**
 * Get recent messages that traversed the fallback chain or were exhausted.
 */
export async function getRecentEscalations(): Promise<FallbackMessageReportRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const client = supabase as any;

  const { data, error } = await client
    .from('message')
    .select(`
      id,
      recipient_phone,
      recipient_type,
      body,
      message_class,
      channel,
      status,
      final_status,
      created_at,
      message_attempt (
        id,
        attempt_number,
        channel,
        status,
        skip_reason,
        error_code,
        dispatched_at,
        completed_at
      ),
      message_cost_ledger (
        id,
        tenant_id,
        campus_id,
        message_id,
        attempt_id,
        channel,
        currency,
        cost_paisa,
        rate_per_unit,
        units,
        status,
        created_at
      )
    `)
    .order('created_at', { ascending: false })
    .limit(30);

  if (error) {
    console.error('getRecentEscalations error:', error);
    return [];
  }

  type RawRow = {
    id: string;
    recipient_phone: string | null;
    recipient_type: string;
    body: string;
    message_class: string;
    channel: CommChannel;
    status: string;
    final_status: string | null;
    created_at: string;
    message_attempt?: any[];
    message_cost_ledger?: MessageCostLedgerRow[];
  };

  const rows = (data || []) as unknown as RawRow[];

  return rows.map((r) => ({
    id: r.id,
    recipient_phone: r.recipient_phone,
    recipient_type: r.recipient_type,
    body: r.body,
    message_class: r.message_class,
    channel: r.channel,
    status: r.status,
    final_status: r.final_status,
    created_at: r.created_at,
    attempts: (r.message_attempt || []).sort((a: any, b: any) => a.attempt_number - b.attempt_number),
    costs: r.message_cost_ledger || [],
  }));
}
