'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { managerSchema } from './schema';

export async function setManager(input: unknown): Promise<{ error: string | null }> {
  const p = managerSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_staff_manager', { p_staff_id: p.data.staffId, p_manager_id: p.data.managerId || null });
  if (error) {
    if (error.message.includes('REPORTING_CYCLE')) return { error: 'That would make someone report to a person below them.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only HR, the principal or the owner can change the org chart.' };
    if (error.message.includes('NOT_FOUND')) return { error: 'That staff member was not found.' };
    return { error: 'Something went wrong. Try again.' };
  }
  revalidatePath('/staff/org-chart');
  return { error: null };
}
