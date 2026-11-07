'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { cnicExpirySchema } from './schema';

export async function setCnicExpiry(input: unknown): Promise<{ error: string | null }> {
  const p = cnicExpirySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: staff } = await supabase.from('staff').select('id').eq('employee_code', p.data.employeeCode).maybeSingle();
  if (!staff) return { error: 'No staff member has that employee code.' };
  const { error } = await supabase.rpc('set_staff_cnic_expiry', { p_staff_id: staff.id, p_expires_on: p.data.expiresOn });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only HR and leadership can do this.' : 'Something went wrong. Try again.' };
  revalidatePath('/staff/hr-dashboard');
  return { error: null };
}
