'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { classTestSchema, marksSchema } from './schemas';

function message(err: { message: string }, fallback: string) {
  if (err.message.includes('FORBIDDEN')) return 'Only teachers and school leaders can manage class tests.';
  if (err.message.includes('MARKS_OUT_OF_RANGE')) return 'Marks cannot be more than the total.';
  if (err.message.includes('SECTION_NOT_FOUND')) return 'Choose a class and section.';
  return fallback;
}

export async function createClassTest(input: z.input<typeof classTestSchema>): Promise<{ error: string | null; id?: string }> {
  const parsed = classTestSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_class_test', {
    p_section_id: parsed.data.sectionId,
    p_subject_id: parsed.data.subjectId || null,
    p_title: parsed.data.title,
    p_test_date: parsed.data.testDate,
    p_total_marks: parsed.data.totalMarks,
  });
  if (error) return { error: message(error, 'Could not create the test.') };
  revalidatePath('/exams/class-tests');
  return { error: null, id: data };
}

export async function saveClassTestMarks(input: z.input<typeof marksSchema>): Promise<{ error: string | null }> {
  const parsed = marksSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Check the marks.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_class_test_marks', { p_test_id: parsed.data.testId, p_rows: parsed.data.rows });
  if (error) return { error: message(error, 'Could not save marks.') };
  revalidatePath(`/exams/class-tests/${parsed.data.testId}`);
  return { error: null };
}

export async function sendClassTestResults(testId: string): Promise<{ error: string | null; queued?: number; skipped?: number }> {
  if (!z.string().uuid().safeParse(testId).success) return { error: 'Unknown test.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('send_class_test_results', { p_test_id: testId });
  if (error) return { error: message(error, 'Could not send results.') };
  const r = data as { queued: number; skipped: number };
  revalidatePath(`/exams/class-tests/${testId}`);
  return { error: null, queued: r.queued, skipped: r.skipped };
}
