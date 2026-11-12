'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { bulkFeePlanOverrideSchema, type BulkFeePlanOverrideInput } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type BulkFeeState = { error: string | null; note?: string };

function feeError(message: string, fallback: string): BulkFeeState {
  if (message.includes('FORBIDDEN')) return { error: 'You do not have permission to make this change.' };
  if (message.includes('OVERRIDE_NOT_PENDING')) return { error: 'Some selected students have no change waiting for approval.' };
  return { error: fallback };
}

export async function changeStudentFees(input: BulkFeePlanOverrideInput): Promise<BulkFeeState> {
  const parsed = bulkFeePlanOverrideSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('bulk_propose_fee_plan_override', {
    p_line_ids: parsed.data.lineIds,
    p_new_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_reason: parsed.data.reason,
    p_approve: parsed.data.approve,
  });
  if (error) return feeError(error.message, 'Could not change the fees.');

  revalidatePath('/fees/student-fees');
  return { error: null, note: parsed.data.approve ? `Fee changed for ${data} students.` : `Sent ${data} changes for approval.` };
}

export async function decideStudentFees(lineIds: string[], approve: boolean): Promise<BulkFeeState> {
  const ids = z.array(z.string().uuid()).min(1).max(2000).safeParse(lineIds);
  if (!ids.success) return { error: 'Select at least one student.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('bulk_decide_fee_plan_override', { p_line_ids: ids.data, p_approve: approve });
  if (error) return feeError(error.message, 'Could not record the decision.');

  revalidatePath('/fees/student-fees');
  return { error: null, note: approve ? `Approved ${data} changes.` : `Rejected ${data} changes.` };
}
