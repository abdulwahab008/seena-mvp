'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const STREAMS = ['hifz', 'nazra', 'qaida'] as const;

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'You are not allowed to do that.';
  if (m.includes('NOT_IN_HALQA')) return 'That student is not in this halqa.';
  if (m.includes('DATE_INVALID')) return 'The date cannot be in the future.';
  if (m.includes('uq_halqa_name')) return 'A halqa with that name already exists.';
  return 'Something went wrong. Try again.';
}

const halqaSchema = z.object({
  campusId: z.string().uuid(),
  name: z.string().trim().min(1, 'Enter a name').max(100),
  stream: z.enum(STREAMS),
  teacherId: z.string().uuid().optional().or(z.literal('')),
});

export async function saveHalqa(input: z.input<typeof halqaSchema>): Promise<{ error: string | null; id?: string }> {
  const p = halqaSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_halqa', { p_campus_id: p.data.campusId, p_name: p.data.name, p_stream: p.data.stream, p_teacher_id: p.data.teacherId || null });
  if (error) return { error: message(error.message) };
  revalidatePath('/hifz');
  return { error: null, id: data };
}

export async function setMember(halqaId: string, studentId: string, member: boolean): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(halqaId).success || !z.string().uuid().safeParse(studentId).success) return { error: 'Invalid selection.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_halqa_member', { p_halqa_id: halqaId, p_student_id: studentId, p_member: member });
  if (error) return { error: message(error.message) };
  revalidatePath('/hifz');
  return { error: null };
}

const para = z.coerce.number().int().min(1).max(30).optional().or(z.literal('').transform(() => undefined));
const count = z.coerce.number().int().min(0).max(1000).optional().or(z.literal('').transform(() => undefined));

const lessonSchema = z.object({
  halqaId: z.string().uuid(),
  studentId: z.string().uuid('Choose a student'),
  lessonDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  lessonType: z.enum(['sabaq', 'sabqi', 'manzil']),
  paraFrom: para,
  paraTo: para,
  portion: z.string().trim().max(200).optional(),
  lines: count,
  mistakes: count,
  tajweedMistakes: count,
  grade: z.enum(['excellent', 'good', 'average', 'weak', 'repeat']).optional().or(z.literal('').transform(() => undefined)),
});

export async function recordLesson(input: unknown): Promise<{ error: string | null }> {
  const p = lessonSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('record_hifz_lesson', {
    p_halqa_id: v.halqaId,
    p_student_id: v.studentId,
    p_lesson_date: v.lessonDate,
    p_lesson_type: v.lessonType,
    p_para_from: v.paraFrom ?? null,
    p_para_to: v.paraTo ?? null,
    p_portion: v.portion ?? null,
    p_lines: v.lines ?? null,
    p_mistakes: v.mistakes ?? 0,
    p_tajweed_mistakes: v.tajweedMistakes ?? 0,
    p_grade: v.grade ?? null,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/hifz');
  return { error: null };
}
