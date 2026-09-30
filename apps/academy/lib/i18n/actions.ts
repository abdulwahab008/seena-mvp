'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { isLang } from './messages';

export async function setLanguage(lang: string): Promise<{ error: string | null }> {
  if (!isLang(lang)) return { error: 'Unsupported language.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_preferred_language', { p_lang: lang });
  if (error) return { error: 'Could not save your language.' };
  revalidatePath('/portal', 'layout');
  revalidatePath('/student', 'layout');
  return { error: null };
}
