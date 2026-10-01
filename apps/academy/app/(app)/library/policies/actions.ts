'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { libraryPolicySchema, type LibraryPolicyInput } from '@/lib/validation';
import { libraryErrorMessage, pkrToPaisa } from '@/lib/library';

type Result = { error: string | null };

export async function savePolicy(input: LibraryPolicyInput): Promise<Result> {
  const p = libraryPolicySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const v = p.data;
  const hasBand = !!v.bandFrom && !!v.bandTo;
  if ((!!v.bandFrom) !== (!!v.bandTo)) return { error: 'Choose both ends of the class band, or neither.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_borrower_policy', {
    p_role: v.role,
    p_max_loans: v.maxLoans,
    p_loan_days: v.loanDays,
    p_max_renewals: v.maxRenewals,
    p_fine_per_day: pkrToPaisa(v.finePerDayPkr) ?? 0,
    p_effective_from: v.effectiveFrom,
    p_campus_id: v.campusId || undefined,
    p_class_band_from: hasBand ? Number(v.bandFrom) : undefined,
    p_class_band_to: hasBand ? Number(v.bandTo) : undefined,
    p_fine_cap: pkrToPaisa(v.fineCapPkr),
    p_block_threshold: pkrToPaisa(v.blockThresholdPkr),
    p_count_working_days_only: v.countWorkingDaysOnly,
  });
  if (error) {
    if (error.message.includes('POLICY_BAND_INVALID')) return { error: 'A class band must run from a lower to a higher class and applies to students only.' };
    if (error.message.includes('POLICY_INVALID')) return { error: 'Check the numbers: the limits are out of range.' };
    return { error: libraryErrorMessage(error.message) };
  }
  revalidatePath('/library/policies');
  return { error: null };
}
