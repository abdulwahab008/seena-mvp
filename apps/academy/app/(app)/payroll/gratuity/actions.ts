'use server';

import { revalidatePath } from 'next/cache';
import { pfSchema } from './schema';
import { supabaseServer } from '@/lib/supabase/server';

export async function addProvidentFund(input: unknown): Promise<{ error: string | null }> {
  const p = pfSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the percentages.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_provident_fund_components', { p_employee_pct: Number(p.data.employeePct), p_employer_pct: Number(p.data.employerPct) });
  if (error) {
    if (error.message.includes('PF_EXISTS')) return { error: 'Provident fund is already set up; change it under Salary Components.' };
    if (error.message.includes('PCT_INVALID')) return { error: 'Shares are up to 20% of basic.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only HR, the accountant or the owner can set this up.' };
    return { error: 'Something went wrong. Try again.' };
  }
  revalidatePath('/payroll/gratuity');
  return { error: null };
}
