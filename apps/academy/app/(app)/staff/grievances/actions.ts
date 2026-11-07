'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const GRIEVANCE_CATEGORIES = ['pay', 'workload', 'conduct', 'harassment', 'facilities', 'policy', 'other'] as const;

const raiseSchema = z.object({
  category: z.enum(GRIEVANCE_CATEGORIES),
  subject: z.string().trim().min(1, 'Enter a subject').max(200),
  description: z.string().trim().min(1, 'Describe the problem').max(4000),
});

export async function raiseGrievance(input: unknown): Promise<{ error: string | null }> {
  const p = raiseSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('raise_staff_grievance', { p_category: p.data.category, p_subject: p.data.subject, p_description: p.data.description });
  if (error) return { error: 'Could not submit. Try again.' };
  revalidatePath('/staff/grievances');
  return { error: null };
}

const handleSchema = z.object({
  id: z.string().uuid(),
  status: z.enum(['in_review', 'resolved', 'dismissed']),
  resolution: z.string().trim().max(2000).optional(),
});

export async function handleGrievance(input: unknown): Promise<{ error: string | null }> {
  const p = handleSchema.safeParse(input);
  if (!p.success) return { error: 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('handle_staff_grievance', { p_id: p.data.id, p_status: p.data.status, p_resolution: p.data.resolution ?? null });
  if (error) {
    if (error.message.includes('RESOLUTION_REQUIRED')) return { error: 'Write the outcome before closing it.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only HR and the owner handle grievances.' };
    return { error: 'This grievance is already closed, or it is your own.' };
  }
  revalidatePath('/staff/grievances');
  return { error: null };
}
