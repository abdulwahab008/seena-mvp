'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { masteryError } from '@/lib/exams/mastery';
import { saveExamQuestionsSchema, saveQuestionMarksSchema } from '@/lib/validation';

/**
 * FR-J07. Capturing a paper's per-question marks: the scheme (questions and the
 * chapter each tests), then the marks. Saving marks refreshes the materialised
 * mastery view once, so the section screen is current straight after a marking
 * session; the nightly job covers everything else.
 */
export type QuestionSheet = {
  exam_subject_id: string;
  questions: { question_no: number; max_marks: number; chapter_no: number | null; topic_tag: string }[];
  students: { enrolment_id: string; roll_no: number | null; student_name: string; gr_number: string; marks: Record<string, number> }[];
};
export type QuestionSheetState = { error: string | null; sheet?: QuestionSheet };
export type SaveState = { error: string | null; message?: string };

export async function readQuestionSheet(examSubjectId: string, sectionId: string): Promise<QuestionSheetState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_question_marks_sheet', { p_exam_subject_id: examSubjectId, p_section_id: sectionId });
  if (error || !data) return { error: error ? masteryError(error.message) : 'Could not read the paper.' };
  return { error: null, sheet: data as unknown as QuestionSheet };
}

export async function saveQuestions(input: unknown): Promise<SaveState> {
  const parsed = saveExamQuestionsSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_exam_questions', {
    p_exam_subject_id: parsed.data.examSubjectId,
    p_questions: parsed.data.questions,
  });
  if (error) return { error: masteryError(error.message) };
  return { error: null, message: `${data ?? 0} questions saved.` };
}

export async function saveQuestionMarks(input: unknown): Promise<SaveState> {
  const parsed = saveQuestionMarksSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_question_marks', {
    p_exam_subject_id: parsed.data.examSubjectId,
    p_rows: parsed.data.rows,
  });
  if (error) return { error: masteryError(error.message) };
  await supabase.rpc('fn_refresh_topic_mastery', {});
  revalidatePath('/exams/mastery');
  return { error: null, message: `${data ?? 0} marks saved.` };
}
