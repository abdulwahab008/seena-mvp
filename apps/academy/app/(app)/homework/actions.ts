'use server';

import { revalidatePath } from 'next/cache';
import { createHomeworkSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-H01: create a homework assignment. The teacher_subject_assignment
// check (is this teacher actually assigned to this section+subject) and
// the due-before-assigned-date validation both live inside
// create_homework() itself — this action only shapes the client error and
// carries the draft/publish choice straight through as p_status.
export async function createHomework(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createHomeworkSchema.safeParse({
    sectionId: formData.get('sectionId'),
    subjectId: formData.get('subjectId'),
    title: formData.get('title'),
    description: formData.get('description') || undefined,
    assignedDate: formData.get('assignedDate'),
    dueDate: formData.get('dueDate'),
    estimatedMinutes: formData.get('estimatedMinutes') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const publishNow = formData.get('publishNow') === 'on';
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_homework', {
    p_section_id: parsed.data.sectionId,
    p_subject_id: parsed.data.subjectId,
    p_title: parsed.data.title,
    p_due_date: parsed.data.dueDate,
    p_assigned_date: parsed.data.assignedDate,
    p_description: parsed.data.description,
    p_estimated_minutes: parsed.data.estimatedMinutes,
    p_status: publishNow ? 'published' : 'draft',
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You are not the assigned subject teacher for that section.' };
    if (error.message.includes('DUE_BEFORE_ASSIGNED')) return { error: 'Due date cannot be before the assigned date.' };
    if (error.message.includes('DESCRIPTION_TOO_LONG')) return { error: 'Description must be 4000 characters or fewer.' };
    if (error.message.includes('SECTION_NOT_FOUND')) return { error: 'Section not found.' };
    return { error: 'Could not create the homework assignment.' };
  }

  revalidatePath('/homework');
  return { error: null };
}

export async function publishHomework(id: string, _prev: ActionState, _formData: FormData): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('publish_homework', { p_id: id });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to publish this assignment.' };
    if (error.message.includes('ALREADY_PUBLISHED')) return { error: 'Already published.' };
    return { error: 'Could not publish the assignment.' };
  }

  revalidatePath('/homework');
  return { error: null };
}
