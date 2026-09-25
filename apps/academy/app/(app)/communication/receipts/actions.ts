'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function fetchDeliveryDashboardData() {
  const supabase = await supabaseServer();

  // 1. Fetch current user & tenant
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id, app_role')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) throw new Error('Tenant context missing');

  // 2. Fetch stats
  const { data: stats } = await (supabase as any)
    .from('v_campaign_delivery_stats')
    .select('*')
    .eq('tenant_id', appUser.tenant_id);

  // 3. Fetch recent receipts (last 50)
  const { data: receipts } = await (supabase as any)
    .from('message_receipt')
    .select('id, provider, provider_ref, status, raw, received_at, message_attempt_id')
    .eq('tenant_id', appUser.tenant_id)
    .order('received_at', { ascending: false })
    .limit(50);

  // 4. Fetch dead letter queue
  const { data: deadLetters } = await (supabase as any)
    .from('dead_letter_receipt')
    .select('id, provider, provider_ref, payload, reason, received_at, expires_at')
    .eq('tenant_id', appUser.tenant_id)
    .order('received_at', { ascending: false })
    .limit(50);

  return {
    stats: stats || [],
    receipts: receipts || [],
    deadLetters: deadLetters || [],
    role: appUser.app_role,
  };
}

export async function runStaleSweeperAction(cutoffHours: number = 24) {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: 'Not authenticated' };

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) return { success: false, error: 'Tenant context missing' };

  const { data, error } = await (supabase as any).rpc('expire_stale_attempts', {
    p_tenant_id: appUser.tenant_id,
    p_cutoff_interval: `${cutoffHours} hours`,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/receipts');
  revalidatePath('/communication/outbox');
  return {
    success: true,
    expiredCount: data?.[0]?.expired_count || 0,
  };
}

export async function submitSimulatedReceiptAction(provider: string, providerRef: string, status: string) {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: 'Not authenticated' };

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) return { success: false, error: 'Tenant context missing' };

  const { data, error } = await (supabase as any).rpc('apply_receipt', {
    p_provider: provider,
    p_payload: { provider_ref: providerRef, status },
    p_tenant_id: appUser.tenant_id,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/receipts');
  revalidatePath('/communication/outbox');
  return { success: true, result: data };
}
