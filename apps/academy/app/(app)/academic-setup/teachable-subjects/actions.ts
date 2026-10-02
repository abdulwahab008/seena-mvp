'use server';

import { revalidatePath } from 'next/cache';
import { createTeachableSubjectSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

function mapError(message: string): string {
  if (message.includes('GRADE_RANGE_INVALID')) return 'The starting class must come before (or equal) the ending class.';
  if (message.includes('STAFF_NOT_FOUND')) return 'Staff member not found.';
  if (message.includes('CLASS_LEVEL_NOT_FOUND')) return 'Class level not found.';
  if (message.includes('TEACHABLE_GRANT_NOT_FOUND')) return 'Approval not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Something went wrong.';
}

export async function createTeachableSubject(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createTeachableSubjectSchema.safeParse({
    staffId: formData.get('staffId'),
    subjectId: formData.get('subjectId'),
    classLevelFromId: formData.get('classLevelFromId'),
    classLevelToId: formData.get('classLevelToId'),
    streamId: formData.get('streamId') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_staff_teachable_subject', {
    p_staff_id: parsed.data.staffId,
    p_subject_id: parsed.data.subjectId,
    p_class_level_from_id: parsed.data.classLevelFromId,
    p_class_level_to_id: parsed.data.classLevelToId,
    p_stream_id: parsed.data.streamId,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/teachable-subjects');
  return { error: null };
}

export async function revokeTeachableSubject(id: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('revoke_staff_teachable_subject', { p_id: id });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/teachable-subjects');
  return { error: null };
}
