'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { toPaisa } from '@/lib/rpc-action';
import { expenseApprovalLimitsSchema, pettyCashLimitsSchema, returnWindowSchema, settlementThresholdSchema, tcNoDuesSchema } from '@/lib/validation';
import { parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  THRESHOLD_RANGE_INVALID: 'The principal limit must be above the amount anyone can approve.',
  petty_cash_cap_within_float: 'The limit per payment cannot be above the float.',
};
const done = (message: string): ActionResult => {
  revalidatePath('/settings/finance-rules');
  return { error: null, message };
};

export async function setExpenseApprovalLimits(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(expenseApprovalLimitsSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_expense_approval_limits', {
    p_campus_id: p.data.campusId,
    p_self_max_paisa: toPaisa(p.data.selfMaxPkr),
    p_principal_max_paisa: toPaisa(p.data.principalMaxPkr),
  });
  return error ? { error: rpcError(error.message, MESSAGES) } : done('Expense approval limits saved.');
}

export async function setPettyCashLimits(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(pettyCashLimitsSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_petty_cash_limits', { p_account_id: p.data.accountId, p_float_paisa: toPaisa(p.data.floatPkr), p_txn_cap_paisa: toPaisa(p.data.txnCapPkr) });
  return error ? { error: rpcError(error.message, MESSAGES) } : done('Petty cash limits saved.');
}

export async function setSettlementThreshold(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(settlementThresholdSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_settlement_owner_threshold', { p_paisa: toPaisa(p.data.thresholdPkr) });
  return error ? { error: rpcError(error.message) } : done('Settlement approval limit saved.');
}

export async function setTcNoDues(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(tcNoDuesSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_tc_requires_no_dues', { p_required: p.data.required === 'yes' });
  return error ? { error: rpcError(error.message) } : done('Transfer certificate rule saved.');
}

export async function setReturnWindow(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(returnWindowSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_inv_return_window', { p_days: p.data.days });
  return error ? { error: rpcError(error.message) } : done('Return window saved.');
}
