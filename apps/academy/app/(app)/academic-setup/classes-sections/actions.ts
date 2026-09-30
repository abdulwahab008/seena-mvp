'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const CreateSectionSchema = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
  classLevelId: z.string().uuid(),
  name: z.string().min(1, 'Section name is required').max(10),
  capacity: z.coerce.number().min(1).max(200).default(40),
  medium: z.enum(['ENGLISH', 'URDU']).default('ENGLISH'),
  shift: z.enum(['MORNING', 'AFTERNOON']).default('MORNING'),
});

const AssignTeacherSchema = z.object({
  sectionId: z.string().uuid(),
  staffId: z.string().uuid(),
  effectiveFrom: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Invalid date format'),
});

export async function createSection(formData: FormData): Promise<{ error: string | null; sectionId?: string }> {
  const parsed = CreateSectionSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
    classLevelId: formData.get('classLevelId'),
    name: formData.get('name'),
    capacity: formData.get('capacity'),
    medium: formData.get('medium') || 'ENGLISH',
    shift: formData.get('shift') || 'MORNING',
  });

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input' };
  }

  const supabase = await supabaseServer();
  const { data, error } = await (supabase.rpc as any)('create_section', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_class_level_id: parsed.data.classLevelId,
    p_name: parsed.data.name.trim().toUpperCase(),
    p_capacity: parsed.data.capacity,
    p_medium: parsed.data.medium,
    p_shift: parsed.data.shift,
  });

  if (error) {
    if (error.message.includes('DUPLICATE_SECTION')) {
      return { error: `A section named "${parsed.data.name}" already exists for this class.` };
    }
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to create sections.' };
    }
    return { error: error.message || 'Failed to create section.' };
  }

  revalidatePath('/academic-setup/classes-sections');
  revalidatePath('/admissions/walk-in');
  return { error: null, sectionId: data as string };
}

export async function assignClassTeacher(formData: FormData): Promise<{ error: string | null; warning?: string | null }> {
  const parsed = AssignTeacherSchema.safeParse({
    sectionId: formData.get('sectionId'),
    staffId: formData.get('staffId'),
    effectiveFrom: formData.get('effectiveFrom'),
  });

  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input' };
  }

  const supabase = await supabaseServer();
  const { data, error } = await (supabase.rpc as any)('assign_class_teacher', {
    p_section_id: parsed.data.sectionId,
    p_staff_id: parsed.data.staffId,
    p_effective_from: parsed.data.effectiveFrom,
  });

  if (error) {
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to assign class teachers.' };
    }
    return { error: error.message || 'Failed to assign class teacher.' };
  }

  revalidatePath('/academic-setup/classes-sections');
  return { error: null, warning: data?.warning ?? null };
}
