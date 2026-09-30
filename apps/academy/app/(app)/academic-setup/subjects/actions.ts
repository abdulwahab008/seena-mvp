'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const SubjectSchema = z.object({
  id: z.string().uuid().optional(),
  code: z
    .string()
    .min(1, 'Subject code is required')
    .max(10, 'Code must be 10 characters or less')
    .transform((v) => v.trim().toUpperCase()),
  name_en: z
    .string()
    .min(1, 'Subject name is required')
    .max(100, 'Name must be 100 characters or less')
    .transform((v) => v.trim()),
  subject_type: z.enum(['CORE', 'ELECTIVE', 'ADDITIONAL', 'NON_EXAMINABLE']).default('CORE'),
  is_examinable: z.boolean().default(true),
  default_max_marks: z.coerce.number().min(1).max(500).nullable().optional(),
});

export type SubjectInput = z.infer<typeof SubjectSchema>;

export async function saveSubject(
  data: SubjectInput,
): Promise<{ error: string | null; id?: string }> {
  const parsed = SubjectSchema.safeParse(data);
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input' };
  }

  const supabase = await supabaseServer();

  if (parsed.data.id) {
    // Update existing subject
    const { error } = await (supabase.rpc as any)('update_subject', {
      p_id: parsed.data.id,
      p_code: parsed.data.code,
      p_name_en: parsed.data.name_en,
      p_subject_type: parsed.data.subject_type,
      p_is_examinable: parsed.data.is_examinable,
      p_default_max_marks: parsed.data.default_max_marks ?? null,
      p_name_ur: parsed.data.name_en, // English only per user requirement
    });

    if (error) {
      if (error.message.includes('FORBIDDEN')) {
        return { error: 'You do not have permission to update subjects.' };
      }
      if (error.message.includes('uq_subject_tenant_code')) {
        return { error: `Subject code "${parsed.data.code}" is already in use.` };
      }
      return { error: error.message || 'Failed to update subject.' };
    }
  } else {
    // Create new subject
    const { data: newId, error } = await (supabase.rpc as any)('create_subject', {
      p_code: parsed.data.code,
      p_name_en: parsed.data.name_en,
      p_name_ur: parsed.data.name_en, // English only per user requirement
      p_subject_type: parsed.data.subject_type,
      p_is_examinable: parsed.data.is_examinable,
      p_default_max_marks: parsed.data.default_max_marks ?? null,
    });

    if (error) {
      if (error.message.includes('FORBIDDEN')) {
        return { error: 'You do not have permission to create subjects.' };
      }
      if (error.message.includes('uq_subject_tenant_code')) {
        return { error: `Subject code "${parsed.data.code}" already exists.` };
      }
      return { error: error.message || 'Failed to create subject.' };
    }

    revalidatePath('/academic-setup/subjects');
    revalidatePath('/academic-setup/competency');
    revalidatePath('/academic-setup/curriculum');
    revalidatePath('/academic-setup/teachable-subjects');
    return { error: null, id: newId as string };
  }

  revalidatePath('/academic-setup/subjects');
  revalidatePath('/academic-setup/competency');
  revalidatePath('/academic-setup/curriculum');
  revalidatePath('/academic-setup/teachable-subjects');
  return { error: null, id: parsed.data.id };
}

export async function toggleSubjectActive(
  id: string,
  is_active: boolean,
): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await (supabase.rpc as any)('set_subject_active', {
    p_id: id,
    p_is_active: is_active,
  });

  if (error) {
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to modify subjects.' };
    }
    return { error: error.message || 'Failed to update subject status.' };
  }

  revalidatePath('/academic-setup/subjects');
  revalidatePath('/academic-setup/competency');
  revalidatePath('/academic-setup/curriculum');
  revalidatePath('/academic-setup/teachable-subjects');
  return { error: null };
}
