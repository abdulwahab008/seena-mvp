'use server';

import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export type StartedQuiz = { title: string; ends_at: string; questions: { id: string; prompt: string; options: string[]; marks: number }[] };

function message(m: string) {
  if (m.includes('ALREADY_SUBMITTED')) return 'You have already submitted this quiz.';
  if (m.includes('QUIZ_NOT_OPEN')) return 'This quiz is not open right now.';
  if (m.includes('TIME_UP')) return 'Time is up, so this attempt could not be submitted.';
  return 'This quiz is not available.';
}

export async function startQuiz(quizId: string): Promise<{ error: string | null; quiz?: StartedQuiz }> {
  if (!z.string().uuid().safeParse(quizId).success) return { error: 'Invalid quiz.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('start_quiz_attempt', { p_quiz_id: quizId });
  if (error) return { error: message(error.message) };
  return { error: null, quiz: data as unknown as StartedQuiz };
}

export async function submitQuiz(quizId: string, answers: number[]): Promise<{ error: string | null; score?: number; maxScore?: number }> {
  const p = z.object({ quizId: z.string().uuid(), answers: z.array(z.number().int().min(-1).max(5)).max(500) }).safeParse({ quizId, answers });
  if (!p.success) return { error: 'Invalid answers.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('submit_quiz_attempt', { p_quiz_id: quizId, p_answers: answers });
  if (error) return { error: message(error.message) };
  const r = data as { score: number; max_score: number };
  return { error: null, score: r.score, maxScore: r.max_score };
}
