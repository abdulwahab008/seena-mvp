'use server';

import { revalidatePath } from 'next/cache';
import { addStaffQualificationSchema, verifyStaffQualificationSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  if (message.includes('STAFF_NOT_FOUND')) return 'Staff member not found.';
  if (message.includes('QUALIFICATION_NOT_FOUND')) return 'Qualification not found.';
  if (message.includes('chk_qualification_year_reasonable')) return 'Year completed is out of a reasonable range.';
  return 'Something went wrong.';
}

export async function addStaffQualification(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = addStaffQualificationSchema.safeParse({
    staffId: formData.get('staffId'),
    level: formData.get('level'),
    discipline: formData.get('discipline'),
    institution: formData.get('institution'),
    yearCompleted: formData.get('yearCompleted'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_staff_qualification', {
    p_staff_id: parsed.data.staffId,
    p_level: parsed.data.level,
    p_discipline: parsed.data.discipline,
    p_institution: parsed.data.institution,
    p_year_completed: parsed.data.yearCompleted,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/staff/qualifications');
  return { error: null };
}

export async function verifyStaffQualification(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = verifyStaffQualificationSchema.safeParse({
    qualificationId: formData.get('qualificationId'),
    status: formData.get('status'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('verify_staff_qualification', {
    p_qualification_id: parsed.data.qualificationId,
    p_status: parsed.data.status,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/staff/qualifications');
  return { error: null };
}
