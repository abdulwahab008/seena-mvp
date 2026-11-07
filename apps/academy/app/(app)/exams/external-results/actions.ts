'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { externalResultSchema } from './schema';

export async function saveExternalResult(input: unknown): Promise<{ error: string | null }> {
  const p = externalResultSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: student } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber).maybeSingle();
  if (!student) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('save_external_result', {
    p_student_id: student.id, p_board: p.data.board, p_exam: p.data.exam, p_exam_year: p.data.examYear,
    p_roll_no: p.data.rollNo, p_obtained: p.data.obtained, p_total: p.data.total, p_grade: p.data.grade,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the exam controller or Principal can enter board results.' };
    if (error.message.includes('chk_external_result_marks')) return { error: 'Obtained marks cannot be more than the total.' };
    return { error: 'Something went wrong. Try again.' };
  }
  revalidatePath('/exams/external-results');
  return { error: null };
}
