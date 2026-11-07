'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export async function joinLiveClass(id: string): Promise<{ error: string | null; url?: string }> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid class.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('join_live_class', { p_id: id });
  if (error) {
    if (error.message.includes('CLASS_NOT_OPEN')) return { error: 'This class opens 15 minutes before it starts.' };
    if (error.message.includes('CLASS_CANCELLED')) return { error: 'This class was cancelled.' };
    return { error: 'This class is not available.' };
  }
  return { error: null, url: data as string };
}
