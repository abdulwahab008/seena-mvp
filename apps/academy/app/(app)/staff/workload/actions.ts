'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export type WorkloadState = { error: string | null; message?: string | null };

export async function refreshWorkload(_prev: WorkloadState, formData: FormData): Promise<WorkloadState> {
  const campus = z.string().uuid().safeParse(formData.get('campus'));
  if (!campus.success) return { error: 'Choose a campus.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('refresh_teacher_load', { p_campus: campus.data });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You cannot refresh the report for this campus.' : 'Could not refresh the report.' };
  revalidatePath('/staff/workload');
  return { error: null, message: 'Report refreshed.' };
}
