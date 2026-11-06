'use server';

import { cookies } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { ACTIVE_CAMPUS_COOKIE } from '@/lib/campus-context';

export async function setActiveCampus(campusId: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { data } = await supabase.from('campus').select('id').eq('id', campusId).eq('status', 'active').maybeSingle();
  if (!data) return { error: 'That campus is not available to you.' };
  (await cookies()).set(ACTIVE_CAMPUS_COOKIE, campusId, { path: '/', sameSite: 'lax', httpOnly: true, maxAge: 60 * 60 * 24 * 365 });
  revalidatePath('/', 'layout');
  return { error: null };
}
