'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { bankQuestionSchema, type BankQuestionInput } from '@/lib/validation';

const PATH = '/exams/question-bank';
type Result = { error: string | null };

function bankError(message: string): string {
  if (message.includes('QUESTION_EXISTS')) return 'This question is already in the bank for this subject.';
  if (message.includes('MCQ_OPTIONS_INVALID')) return 'An MCQ needs four options and the correct option.';
  if (message.includes('CHAPTER_REQUIRED')) return 'Enter the chapter.';
  if (message.includes('FORBIDDEN')) return 'You can add questions only for subjects you teach.';
  if (message.includes('NOT_FOUND')) return 'That class subject or question was not found.';
  return 'Could not save the question.';
}

export async function addBankQuestion(input: BankQuestionInput): Promise<Result> {
  const p = bankQuestionSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const v = p.data;
  const mcq = v.type === 'mcq';
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_bank_question', {
    p_class_subject_id: v.classSubjectId,
    p_chapter: v.chapter,
    p_type: v.type,
    p_marks: v.marks,
    p_text: v.text,
    p_options: mcq ? [v.optionA, v.optionB, v.optionC, v.optionD] : undefined,
    p_answer: v.answer || undefined,
    p_difficulty: v.difficulty,
  });
  if (error) return { error: bankError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function setBankQuestionActive(id: string, active: boolean): Promise<Result> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid question.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_bank_question_active', { p_id: id, p_active: active });
  if (error) return { error: bankError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}
