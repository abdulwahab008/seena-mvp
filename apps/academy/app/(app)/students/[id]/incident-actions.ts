'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const schema = z.object({
  studentId: z.string().uuid(),
  occurredOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  category: z.enum(['behaviour', 'bullying', 'attendance', 'uniform', 'academic_dishonesty', 'property_damage', 'other']),
  severity: z.enum(['minor', 'moderate', 'serious']),
  description: z.string().trim().min(1, 'Describe what happened').max(2000),
  actionTaken: z.string().trim().max(1000).optional(),
  parentInformed: z.boolean(),
});

export async function recordIncident(input: z.input<typeof schema>): Promise<{ error: string | null }> {
  const p = schema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('record_student_incident', {
    p_student_id: p.data.studentId,
    p_occurred_on: p.data.occurredOn,
    p_category: p.data.category,
    p_severity: p.data.severity,
    p_description: p.data.description,
    p_action_taken: p.data.actionTaken,
    p_parent_informed: p.data.parentInformed,
  });
  if (error) {
    if (error.message.includes('DATE_INVALID')) return { error: 'An incident cannot be in the future.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You cannot record incidents for this student.' };
    return { error: 'Could not save the incident.' };
  }
  revalidatePath(`/students/${p.data.studentId}`);
  return { error: null };
}
