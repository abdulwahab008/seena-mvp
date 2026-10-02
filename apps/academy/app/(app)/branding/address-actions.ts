'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { campusAddressSchema, type CampusAddressInput } from '@/lib/validation';

// FR-S09: the campus address printed under the school name on report letterhead.
export async function saveCampusAddress(input: CampusAddressInput): Promise<{ error: string | null }> {
  const p = campusAddressSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_campus_address', { p_campus_id: p.data.campusId, p_address_en: p.data.addressEn ?? '', p_address_ur: p.data.addressUr ?? '' });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the owner or a principal can change a campus address.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'That campus is not available to you.' };
    return { error: 'Something went wrong. Please try again.' };
  }
  revalidatePath('/branding');
  return { error: null };
}
