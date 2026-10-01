'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import {
  pettyCashAccountSchema,
  pettyCashPaymentSchema,
  pettyCashReplenishSchema,
  type PettyCashAccountInput,
  type PettyCashPaymentInput,
  type PettyCashReplenishInput,
} from '@/lib/validation';

export type PettyResult = { error: string | null; useVoucher?: boolean };

const MESSAGES: [string, string][] = [
  ['insufficient_petty_cash', 'There is not enough cash in the tin for this payment.'],
  ['RECONCILIATION_PENDING', 'A count is waiting for sign-off, so the tin is frozen until the Principal decides.'],
  ['EXPLANATION_REQUIRED', 'The count differs from the system. Explain the difference in at least 20 characters.'],
  ['RECONCILIATION_ALREADY_PENDING', 'A count is already waiting for sign-off.'],
  ['CANNOT_APPROVE_OWN_COUNT', 'You cannot approve a count you made.'],
  ['COUNT_STALE', 'The balance moved after the count. Reject it and count again.'],
  ['RECONCILIATION_REQUIRED_BEFORE_HANDOVER', 'Count and replenish the tin before it changes hands.'],
  ['PETTY_CASH_ACCOUNT_EXISTS', 'This campus already has a petty cash account.'],
  ['CUSTODIAN_NOT_FOUND', 'That custodian was not found.'],
  ['EXPENSE_HEAD_NOT_FOUND', 'That expense head is not available.'],
  ['FORBIDDEN', 'You do not have permission for this step.'],
];
const mapError = (message: string) => MESSAGES.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
const toPaisa = (pkr: number) => Math.round(pkr * 100);
const firstIssue = (e: z.ZodError | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

async function run(fn: (s: Awaited<ReturnType<typeof supabaseServer>>) => PromiseLike<{ error: { message: string } | null }>): Promise<PettyResult> {
  const supabase = await supabaseServer();
  const { error } = await fn(supabase);
  if (error) {
    if (error.message.includes('petty_cash_txn_cap_exceeded')) return { error: 'This is above the per-payment cap. Raise a full expense voucher instead.', useVoucher: true };
    return { error: mapError(error.message) };
  }
  revalidatePath('/expenses/petty-cash');
  return { error: null };
}

export async function payFromPettyCash(input: PettyCashPaymentInput): Promise<PettyResult> {
  const p = pettyCashPaymentSchema.safeParse(input);
  if (!p.success) return { error: firstIssue(p.error) };
  return run((s) => s.rpc('post_petty_cash', { p_account_id: p.data.accountId, p_amount_paisa: toPaisa(p.data.amountPkr), p_head_id: p.data.headId, p_narrative: p.data.narrative }));
}

export async function requestReplenishment(input: PettyCashReplenishInput): Promise<PettyResult> {
  const p = pettyCashReplenishSchema.safeParse(input);
  if (!p.success) return { error: firstIssue(p.error) };
  return run((s) => s.rpc('request_petty_cash_replenishment', { p_account_id: p.data.accountId, p_counted_paisa: toPaisa(p.data.countedPkr), p_explanation: p.data.explanation }));
}

export async function decideReplenishment(reconciliationId: string, approve: boolean): Promise<PettyResult> {
  if (!z.string().uuid().safeParse(reconciliationId).success) return { error: 'Invalid request.' };
  return run((s) => s.rpc('decide_petty_cash_replenishment', { p_reconciliation_id: reconciliationId, p_approve: approve }));
}

export async function createAccount(input: PettyCashAccountInput): Promise<PettyResult> {
  const p = pettyCashAccountSchema.safeParse(input);
  if (!p.success) return { error: firstIssue(p.error) };
  return run((s) => s.rpc('create_petty_cash_account', { p_campus_id: p.data.campusId, p_float_paisa: toPaisa(p.data.floatPkr), p_txn_cap_paisa: toPaisa(p.data.capPkr), p_custodian_user_id: p.data.custodianId }));
}

export async function changeCustodian(accountId: string, custodianId: string): Promise<PettyResult> {
  if (!z.string().uuid().safeParse(accountId).success || !z.string().uuid().safeParse(custodianId).success) return { error: 'Choose a custodian.' };
  return run((s) => s.rpc('change_petty_cash_custodian', { p_account_id: accountId, p_new_custodian_user_id: custodianId }));
}
