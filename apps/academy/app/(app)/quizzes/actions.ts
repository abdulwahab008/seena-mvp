'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'You cannot change this quiz.';
  if (m.includes('QUIZ_PUBLISHED')) return 'A published quiz cannot be changed.';
  if (m.includes('QUIZ_EMPTY')) return 'Add at least one question first.';
  if (m.includes('chk_quiz_window')) return 'The quiz must close after it opens.';
  if (m.includes('chk_quiz_question_correct')) return 'The correct option number is not one of the options.';
  return 'Something went wrong. Try again.';
}

const quizSchema = z.object({
  sectionId: z.string().uuid('Choose a section'),
  title: z.string().trim().min(1, 'Enter a title').max(200),
  opensAt: z.string().datetime(),
  closesAt: z.string().datetime(),
  durationMin: z.coerce.number().int().min(1).max(300),
});

export async function createQuiz(input: unknown): Promise<{ error: string | null; id?: string }> {
  const p = quizSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_quiz', {
    p_section_id: p.data.sectionId,
    p_title: p.data.title,
    p_opens_at: p.data.opensAt,
    p_closes_at: p.data.closesAt,
    p_duration_min: p.data.durationMin,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/quizzes');
  return { error: null, id: data };
}

const questionSchema = z.object({
  quizId: z.string().uuid(),
  prompt: z.string().trim().min(1, 'Enter the question').max(2000),
  options: z.array(z.string().trim().min(1)).min(2, 'Give at least two options').max(6, 'At most six options'),
  correct: z.coerce.number().int().min(1),
  marks: z.coerce.number().int().min(1).max(100),
});

export async function addQuestion(input: unknown): Promise<{ error: string | null }> {
  const p = questionSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  if (p.data.correct > p.data.options.length) return { error: 'The correct option number is not one of the options.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_quiz_question', {
    p_quiz_id: p.data.quizId,
    p_prompt: p.data.prompt,
    p_options: p.data.options,
    p_correct_index: p.data.correct - 1,
    p_marks: p.data.marks,
  });
  if (error) return { error: message(error.message) };
  revalidatePath(`/quizzes/${p.data.quizId}`);
  return { error: null };
}

export async function publishQuiz(quizId: string): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(quizId).success) return { error: 'Invalid quiz.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('publish_quiz', { p_quiz_id: quizId });
  if (error) return { error: message(error.message) };
  revalidatePath(`/quizzes/${quizId}`);
  return { error: null };
}
