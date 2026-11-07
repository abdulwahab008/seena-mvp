'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const schema = z.object({
  campusId: z.string().uuid(),
  title: z.string().trim().min(1, 'Enter a title').max(200),
  provider: z.string().trim().max(200).optional(),
  heldOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  hours: z.coerce.number().positive('Enter the hours').max(500),
  isMandatory: z.boolean(),
  staffIds: z.array(z.string().uuid()),
});

export async function saveProgram(input: unknown): Promise<{ error: string | null }> {
  const p = schema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_training_program', {
    p_campus_id: p.data.campusId,
    p_title: p.data.title,
    p_provider: p.data.provider ?? null,
    p_held_on: p.data.heldOn,
    p_hours: p.data.hours,
    p_is_mandatory: p.data.isMandatory,
    p_staff_ids: p.data.staffIds,
  });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'Only HR can record training.' : 'Could not save the program.' };
  revalidatePath('/staff/training');
  return { error: null };
}
