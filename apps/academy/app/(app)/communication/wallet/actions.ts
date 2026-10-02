'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function fetchWalletDashboardData() {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error('Not authenticated');

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id, app_role')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) throw new Error('Tenant context missing');

  // 1. Fetch wallet
  const { data: wallet } = await (supabase as any)
    .from('tenant_comm_wallet')
    .select('*')
    .eq('tenant_id', appUser.tenant_id)
    .maybeSingle();

  // If no wallet exists yet, initialize with 0
  let balancePaisa = wallet?.balance_paisa ? Number(wallet.balance_paisa) : 0;
  if (!wallet) {
    await (supabase as any)
      .from('tenant_comm_wallet')
      .insert({ tenant_id: appUser.tenant_id, balance_paisa: 0 });
  }

  // 2. Fetch rate cards
  const { data: rateCards } = await (supabase as any)
    .from('provider_rate_card')
    .select('*')
    .order('channel', { ascending: true })
    .order('effective_from', { ascending: false });

  // 3. Fetch recent wallet transactions
  const { data: txns } = await (supabase as any)
    .from('tenant_comm_wallet_txn')
    .select('*')
    .eq('tenant_id', appUser.tenant_id)
    .order('created_at', { ascending: false })
    .limit(25);

  // 4. Fetch recent cost ledger rows
  const { data: ledger } = await (supabase as any)
    .from('comm_cost_ledger')
    .select('*')
    .eq('tenant_id', appUser.tenant_id)
    .order('created_at', { ascending: false })
    .limit(25);

  // 5. Monthly spend
  const { data: monthlySpend } = await (supabase as any)
    .from('v_monthly_comm_spend')
    .select('*')
    .eq('tenant_id', appUser.tenant_id);

  return {
    balancePaisa,
    currency: wallet?.currency || 'PKR',
    rateCards: rateCards || [],
    transactions: txns || [],
    ledger: ledger || [],
    monthlySpend: monthlySpend || [],
    role: appUser.app_role,
  };
}

export async function topUpWalletAction(amountPkr: number, reference: string = 'Manual Top-up') {
  const supabase = await supabaseServer();

  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { success: false, error: 'Not authenticated' };

  const { data: appUser } = await supabase
    .from('app_user')
    .select('tenant_id')
    .eq('user_id', user.id)
    .single();

  if (!appUser?.tenant_id) return { success: false, error: 'Tenant context missing' };

  const paisa = Math.round(amountPkr * 100);
  if (paisa <= 0) return { success: false, error: 'Top-up amount must be greater than zero' };

  const { data, error } = await (supabase as any).rpc('top_up_comm_wallet', {
    p_tenant_id: appUser.tenant_id,
    p_paisa: paisa,
    p_reference: reference,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  revalidatePath('/communication/wallet');
  return { success: true, newBalancePaisa: data };
}

export async function checkCampaignCreditGuardAction(batchId: string) {
  const supabase = await supabaseServer();

  const { data, error } = await (supabase as any).rpc('guard_campaign_dispatch', {
    p_batch_id: batchId,
  });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true, result: data };
}
