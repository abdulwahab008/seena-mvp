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

const CreateClassSchema = z.object({
  name: z.string().trim().min(1, 'Class name is required').max(60),
  code: z.string().trim().toUpperCase().regex(/^[A-Z0-9-]{1,10}$/, 'Code is 1 to 10 letters, numbers or dashes'),
  position: z.enum(['start', 'end']),
});

// Ordinal sets promotion order, so a new class goes before the first one
// (e.g. Playgroup) or after the last one.
export async function createClassLevel(formData: FormData): Promise<{ error: string | null }> {
  const parsed = CreateClassSchema.safeParse({
    name: formData.get('name'),
    code: formData.get('code'),
    position: formData.get('position'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input' };

  const supabase = await supabaseServer();
  const { data: edge } = await supabase
    .from('class_level')
    .select('ordinal')
    .order('ordinal', { ascending: parsed.data.position === 'start' })
    .limit(1)
    .maybeSingle();
  const ordinal = edge ? edge.ordinal + (parsed.data.position === 'start' ? -1 : 1) : 0;

  const { error } = await supabase.rpc('create_class_level', {
    p_code: parsed.data.code,
    p_name_en: parsed.data.name,
    p_name_ur: '',
    p_ordinal: ordinal,
  });
  if (error) {
    if (error.code === '23505') return { error: `A class with code "${parsed.data.code}" already exists.` };
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can add classes.' };
    return { error: 'Could not add the class.' };
  }

  revalidatePath('/academic-setup/classes-sections');
  return { error: null };
}

export async function renameClassLevel(id: string, name: string): Promise<{ error: string | null }> {
  const parsed = z.object({ id: z.string().uuid(), name: z.string().trim().min(1, 'Class name is required').max(60) }).safeParse({ id, name });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('rename_class_level', { p_id: parsed.data.id, p_name_en: parsed.data.name });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only an Owner or Principal can rename classes.' };
    return { error: 'Could not rename the class.' };
  }

  revalidatePath('/academic-setup/classes-sections');
  return { error: null };
}

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
