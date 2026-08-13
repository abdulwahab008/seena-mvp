'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';
import { decideExpenseVoucherSchema } from '@/lib/validation';
import { expenseError } from '@/lib/expenses/errors';

/**
 * FR-L11 AC2 + AC4. decide_expense_voucher() is the only writer of an
 * approval row, and expense_voucher_approval is append-only, so there is no
 * "undo" action here and there is nothing to write one with.
 */

export type DecideVoucherState = { error: string | null; voucherId?: string; decision?: string };

export async function decideExpenseVoucher(formData: FormData): Promise<DecideVoucherState> {
  const parsed = decideExpenseVoucherSchema.safeParse({
    voucherId: formData.get('voucherId'),
    decision: formData.get('decision'),
    reason: formData.get('reason') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('decide_expense_voucher', {
    p_voucher_id: parsed.data.voucherId,
    p_decision: parsed.data.decision,
    p_reason: parsed.data.reason || undefined,
    // AC4: the address this decision was made from. See lib/request-ip.ts.
    p_request_ip: clientIpFromHeaders(await headers()) ?? undefined,
  });
  if (error || !data) return { error: error ? expenseError(error.message) : 'Could not record the decision.' };

  revalidatePath('/expenses/approvals');
  revalidatePath('/expenses/vouchers');
  return { error: null, voucherId: parsed.data.voucherId, decision: parsed.data.decision };
}
