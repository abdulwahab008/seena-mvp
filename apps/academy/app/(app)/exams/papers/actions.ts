'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { createPaperJob, paperRequestError } from '@/lib/exams/paper-request';
import {
  boardPatternSchema,
  buildSetsSchema,
  type BuildSetsInput,
  cooldownSettingsSchema,
  paperRequestSchema,
  parseChapters,
  publishPaperSchema,
  replaceQuestionSchema,
  type BoardPatternInput,
  type CooldownSettingsInput,
  type PaperRequestFormInput,
  type PublishPaperInput,
  type ReplaceQuestionInput,
} from '@/lib/validation';

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

// FR-I07.
function setsError(message: string, details?: string | null): string {
  const pool = /insufficient_pool: (.+)/.exec(message);
  if (pool) return `Not enough usable questions in the bank for ${pool[1]!.split('\n')[0]}. ${details ?? ''} The sets were not built, rather than building near-duplicates.`.trim();
  if (message.includes('PAPER_SET_EXISTS')) return 'This paper already has draft sets. Tick "replace the existing drafts" to rebuild them.';
  if (message.includes('PAPER_PUBLISHED')) return 'A paper for this subject is already published and cannot be replaced.';
  if (message.includes('CELLS_MISMATCH')) return details ?? 'The chapter plan does not match the pattern.';
  if (message.includes('CHAPTERS_REQUIRED')) return 'Choose at least one chapter.';
  return paperRequestError(message);
}

export async function buildSets(input: BuildSetsInput): Promise<Result & { paperIds?: string[] }> {
  const p = buildSetsSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const chapters = parseChapters(p.data.chaptersText);
  if (chapters.length === 0) return { error: 'Enter at least one chapter' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('build_paper_sets', {
    p_exam_subject_id: p.data.examSubjectId,
    p_board_pattern_id: p.data.boardPatternId,
    p_chapters: chapters,
    p_set_count: p.data.setCount,
    p_max_identical: p.data.maxIdentical,
    p_replace: p.data.replace,
  });
  if (error) return { error: setsError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null, paperIds: (data ?? []) as string[] };
}

// FR-I06.
function publishError(message: string, details?: string | null): string {
  if (message.includes('COOLDOWN_BLOCKED')) return `${details ?? 'Some questions were used by this class recently.'} Enter an override reason to publish anyway.`;
  if (message.includes('OVERRIDE_REASON_TOO_SHORT')) return 'The override reason needs at least 10 characters.';
  if (message.includes('PAPER_NOT_DRAFT')) return 'Only a draft paper can be changed or published.';
  if (message.includes('PAPER_NOT_FOUND')) return 'Paper not found.';
  if (message.includes('QUESTION_TEXT_INVALID')) return 'The question must be between 1 and 2000 characters.';
  if (message.includes('QUESTION_NOT_FOUND')) return 'Question not found.';
  return paperRequestError(message);
}

export async function publishPaper(input: PublishPaperInput): Promise<Result & { flagged?: number; overridden?: boolean }> {
  const p = publishPaperSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('publish_exam_paper', { p_paper_id: p.data.paperId, p_override_reason: p.data.overrideReason || undefined });
  if (error) return { error: publishError(error.message, error.details) };
  revalidatePath(PATH);
  revalidatePath(`${PATH}/${p.data.paperId}`);
  const result = data as unknown as { flagged_count: number; overridden: boolean };
  return { error: null, flagged: result.flagged_count, overridden: result.overridden };
}

export async function replaceQuestion(paperId: string, input: ReplaceQuestionInput): Promise<Result> {
  const p = replaceQuestionSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('replace_paper_question', { p_item_id: p.data.itemId, p_text: p.data.text });
  if (error) return { error: publishError(error.message) };
  revalidatePath(`${PATH}/${paperId}`);
  return { error: null };
}

export async function saveCooldownSettings(input: CooldownSettingsInput): Promise<Result> {
  const p = cooldownSettingsSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_exam_settings', {
    p_campus_id: p.data.campusId,
    p_settings: { question_cooldown_terms: p.data.questionCooldownTerms, cooldown_mode: p.data.cooldownMode },
  });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You do not have permission to do that.' : 'One of the settings is out of range.' };
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
