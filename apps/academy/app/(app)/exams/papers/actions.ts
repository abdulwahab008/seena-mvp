'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { createPaperJob, paperRequestError } from '@/lib/exams/paper-request';
import { boardPatternSchema, paperRequestSchema, parseChapters, type BoardPatternInput, type PaperRequestFormInput } from '@/lib/validation';

/**
 * FR-I05. A request is one RPC that writes a queued job row; the generation
 * itself happens in the worker and arrives through the signed callback.
 */
const PATH = '/exams/papers';
type Result = { error: string | null };

export async function requestPaper(input: PaperRequestFormInput): Promise<Result & { jobId?: string }> {
  const p = paperRequestSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const chapters = parseChapters(p.data.chaptersText);
  if (chapters.length === 0) return { error: 'Enter at least one chapter' };
  const supabase = await supabaseServer();
  const { jobId, error } = await createPaperJob(supabase, {
    examSubjectId: p.data.examSubjectId,
    boardPatternId: p.data.boardPatternId,
    chapters,
    totalMarks: p.data.totalMarks,
    setCount: p.data.setCount,
  });
  if (error) return { error };
  revalidatePath(PATH);
  return { error: null, jobId: jobId ?? undefined };
}

export async function retryJob(jobId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(jobId).success) return { error: 'Invalid job.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('retry_paper_job', { p_job_id: jobId });
  if (error) return { error: paperRequestError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function savePattern(input: BoardPatternInput): Promise<Result> {
  const p = boardPatternSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const sections = [
    { type: 'mcq', name: 'Section A (MCQ)', count: p.data.mcqCount, marks_each: p.data.mcqMarks },
    { type: 'short', name: 'Section B (short questions)', count: p.data.shortCount, marks_each: p.data.shortMarks },
    { type: 'long', name: 'Section C (long questions)', count: p.data.longCount, marks_each: p.data.longMarks },
  ]
    .filter((s) => s.count > 0 && s.marks_each > 0)
    .map((s, i) => ({ no: i + 1, ...s }));
  if (sections.length === 0) return { error: 'The pattern needs at least one question' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_board_pattern', { p_code: p.data.code, p_name: p.data.name, p_board: p.data.board, p_sections: sections });
  if (error) return { error: paperRequestError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}
