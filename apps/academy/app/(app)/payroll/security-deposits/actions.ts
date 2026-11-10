'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { depositSchema } from './schema';

export async function createSecurityDeposit(input: z.input<typeof depositSchema>): Promise<{ error: string | null }> {
  const parsed = depositSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_staff_security_deposit', {
    p_staff_id: parsed.data.staffId,
    p_target_paisa: parsed.data.targetPkr * 100,
    p_installment_paisa: parsed.data.installmentPkr * 100,
    p_start_month: `${parsed.data.startMonth}-01`,
    p_notes: parsed.data.notes || undefined,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only HR, the Accountant or the Owner can set up security deposits.' };
    if (error.message.includes('DEPOSIT_EXISTS')) return { error: 'This staff member already has a security deposit.' };
    return { error: 'Could not save the deposit. Try again.' };
  }
  revalidatePath('/payroll/security-deposits');
  return { error: null };
}
