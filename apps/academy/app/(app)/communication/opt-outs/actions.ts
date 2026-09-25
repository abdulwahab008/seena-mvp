'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function fetchOptOutDashboardData() {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id, app_role')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) throw new Error('Tenant context missing');

  // 1. Fetch active opt-outs
  const { data: optOuts } = await (supabase as any)
    .from('comm_opt_out')
    .select('*')
    .eq('tenant_id', appUser.tenant_id)
    .order('opted_out_at', { ascending: false });

  // 2. Fetch inbound SMS
  const { data: inbounds } = await (supabase as any)
    .from('inbound_sms')
    .select('*')
    .eq('tenant_id', appUser.tenant_id)
    .order('received_at', { ascending: false })
    .limit(50);

  // 3. Fetch audit log
  const { data: audits } = await (supabase as any)
    .from('comm_opt_out_audit')
    .select('*')
    .eq('tenant_id', appUser.tenant_id)
    .order('created_at', { ascending: false })
    .limit(50);

  return {
    optOuts: optOuts || [],
    inbounds: inbounds || [],
    audits: audits || [],
    role: appUser.app_role,
  };
}

export async function manualOptOutAction(phone: string, channel: string = 'sms', reason: string = 'Staff action') {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: 'Not authenticated' };

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) return { success: false, error: 'Tenant context missing' };

  const { error } = await (supabase as any)
    .from('comm_opt_out')
    .upsert({
      tenant_id: appUser.tenant_id,
      recipient_phone: phone.trim(),
      channel,
      reason,
      source: 'staff',
      created_by: user.id,
      opted_out_at: new Date().toISOString(),
    }, { onConflict: 'tenant_id,recipient_phone,channel' });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/opt-outs');
  return { success: true };
}

export async function resubscribeAction(phone: string, channel: string = 'sms', reason: string = 'Parent portal toggle') {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: 'Not authenticated' };

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) return { success: false, error: 'Tenant context missing' };

  const { data, error } = await (supabase as any).rpc('resubscribe_recipient', {
    p_tenant_id: appUser.tenant_id,
    p_phone: phone.trim(),
    p_channel: channel,
    p_actor_id: user.id,
    p_reason: reason,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/opt-outs');
  return { success: true, result: data };
}

export async function simulateInboundStopAction(phone: string, keyword: string) {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: 'Not authenticated' };

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) return { success: false, error: 'Tenant context missing' };

  const { data, error } = await (supabase as any)
    .from('inbound_sms')
    .insert({
      tenant_id: appUser.tenant_id,
      from_phone: phone.trim(),
      to_mask: 'SEENA',
      body: keyword.trim(),
    })
    .select()
    .single();

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/opt-outs');
  return { success: true, record: data };
}
