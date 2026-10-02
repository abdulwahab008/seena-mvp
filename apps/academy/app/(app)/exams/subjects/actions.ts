'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { examSubjectError } from '@/lib/exams/errors';
import { examSubjectIdSchema, upsertExamSubjectSchema } from '@/lib/validation';

/**
 * FR-I02. exam_subject and exam_subject_component have SELECT policies and
 * no write policies, so upsert_exam_subject() and delete_exam_subject() are
 * the only writers. The component set is sent whole, not row by row: a
 * half-applied edit would leave a total max nobody chose.
 */

const PATH = '/exams/subjects';

export type ExamSubjectState = { error: string | null };

export async function upsertExamSubject(_prev: ExamSubjectState, formData: FormData): Promise<ExamSubjectState> {
  let components: unknown;
  try {
    components = JSON.parse(String(formData.get('components') ?? '[]'));
  } catch {
    return { error: 'Invalid input.' };
  }

  const parsed = upsertExamSubjectSchema.safeParse({
    examTermId: formData.get('examTermId'),
    classSubjectId: formData.get('classSubjectId'),
    components,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_exam_subject', {
    p_exam_term_id: parsed.data.examTermId,
    p_class_subject_id: parsed.data.classSubjectId,
    p_components: parsed.data.components.map((c) => ({
      component: c.component,
      max_marks: c.maxMarks,
      pass_marks: c.passMarks,
    })),
  });
  if (error) return { error: examSubjectError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}

export async function deleteExamSubject(formData: FormData): Promise<ExamSubjectState> {
  const parsed = examSubjectIdSchema.safeParse({ examSubjectId: formData.get('examSubjectId') });
  if (!parsed.success) return { error: 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_exam_subject', { p_exam_subject_id: parsed.data.examSubjectId });
  if (error) return { error: examSubjectError(error.message) };

  revalidatePath(PATH);
  return { error: null };
}
