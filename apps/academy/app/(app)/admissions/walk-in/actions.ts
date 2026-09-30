'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { revalidatePath } from 'next/cache';

export async function createSectionAction(
  formData: FormData
): Promise<{ error: string | null; sectionId: string | null; name: string | null }> {
  const campusId = formData.get('campusId')?.toString();
  const sessionId = formData.get('sessionId')?.toString();
  const classLevelId = formData.get('classLevelId')?.toString();
  const name = formData.get('name')?.toString()?.trim()?.toUpperCase();
  const capacityStr = formData.get('capacity')?.toString();
  const capacity = capacityStr ? parseInt(capacityStr, 10) : 40;

  if (!campusId || !sessionId || !classLevelId) {
    return { error: 'Campus, session, and class are required.', sectionId: null, name: null };
  }
  if (!name) {
    return { error: 'Section name is required (e.g. A, B, Green).', sectionId: null, name: null };
  }

  const supabase = await supabaseServer();
  const { data, error } = await (supabase.rpc as any)('create_section', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_class_level_id: classLevelId,
    p_name: name,
    p_capacity: isNaN(capacity) ? 40 : capacity,
    p_medium: 'ENGLISH',
    p_shift: 'MORNING',
  });

  if (error) {
    if (error.message.includes('SECTION_NAME_DUPLICATE')) {
      return { error: `Section "${name}" already exists for this class.`, sectionId: null, name: null };
    }
    return { error: error.message || 'Failed to create section.', sectionId: null, name: null };
  }

  revalidatePath('/admissions/walk-in');
  revalidatePath('/academic-setup/curriculum');
  return { error: null, sectionId: data as string, name };
}
