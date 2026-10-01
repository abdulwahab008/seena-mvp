'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { datesheetError } from '@/lib/exams/datesheet-errors';
import {
  createDatesheetSchema,
  datesheetSlotSchema,
  examHallSchema,
  examSettingsSchema,
  type CreateDatesheetInput,
  type DatesheetSlotInput,
  type ExamHallInput,
  type ExamSettingsInput,
} from '@/lib/validation';

/**
 * FR-I03. Nothing here writes a table directly: datesheet, datesheet_slot and
 * exam_hall have a SELECT policy and no write policy, so every change goes
 * through save_datesheet_slot() / save_exam_hall() / create_datesheet(), which
 * gate the role and campus themselves.
 */

const PATH = '/exams/datesheet';

export type SlotWarning = { code: string; severity: 'note' | 'warning'; message: string };
export type SlotResult = { error: string | null; warnings?: SlotWarning[] };
type Result = { error: string | null };

export async function createDatesheet(input: CreateDatesheetInput): Promise<Result> {
  const p = createDatesheetSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_datesheet', { p_campus_id: p.data.campusId, p_exam_term_id: p.data.examTermId, p_title: p.data.title });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null };
}

export async function saveHall(input: ExamHallInput): Promise<Result> {
  const p = examHallSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_exam_hall', {
    p_campus_id: p.data.campusId,
    p_code: p.data.code,
    p_name: p.data.name,
    p_rows_count: p.data.rowsCount,
    p_seats_per_row: p.data.seatsPerRow,
  });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null };
}

export async function saveSlot(input: DatesheetSlotInput): Promise<SlotResult> {
  const p = datesheetSlotSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_datesheet_slot', {
    p_datesheet_id: p.data.datesheetId,
    p_exam_subject_id: p.data.examSubjectId,
    p_exam_date: p.data.examDate,
    p_start_time: p.data.startTime,
    p_end_time: p.data.endTime,
    p_hall_id: p.data.hallId || undefined,
    p_invigilators: p.data.invigilators,
  });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  const warnings = ((data as { warnings?: SlotWarning[] } | null)?.warnings ?? []) as SlotWarning[];
  return { error: null, warnings };
}

export async function deleteSlot(slotId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(slotId).success) return { error: 'Invalid slot.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_datesheet_slot', { p_slot_id: slotId });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null };
}

// FR-I04.
export async function publishDatesheet(datesheetId: string, note: string): Promise<Result & { version?: number }> {
  if (!z.string().uuid().safeParse(datesheetId).success) return { error: 'Invalid datesheet.' };
  if (note.length > 500) return { error: 'The note can be at most 500 characters.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('publish_datesheet', { p_datesheet_id: datesheetId, p_note: note.trim() || undefined });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null, version: data ?? undefined };
}

export async function reopenDatesheet(datesheetId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(datesheetId).success) return { error: 'Invalid datesheet.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reopen_datesheet', { p_datesheet_id: datesheetId });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null };
}

export async function saveExamSettings(input: ExamSettingsInput): Promise<Result> {
  const p = examSettingsSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const { campusId, ...rest } = p.data;
  const patch: Record<string, string | number | null> = {};
  if (rest.jummahCutoff !== undefined) patch.jummah_cutoff = rest.jummahCutoff;
  if (rest.questionCooldownTerms !== undefined) patch.question_cooldown_terms = rest.questionCooldownTerms;
  if (rest.cooldownMode !== undefined) patch.cooldown_mode = rest.cooldownMode;
  if (rest.maxModerationDelta !== undefined) patch.max_moderation_delta = rest.maxModerationDelta;
  if (rest.maxModerationPct !== undefined) patch.max_moderation_pct = rest.maxModerationPct;
  if (rest.paperReleaseOffsetMinutes !== undefined) patch.paper_release_offset_minutes = rest.paperReleaseOffsetMinutes;
  if (rest.invigilationMaxDuties !== undefined) patch.invigilation_max_duties = rest.invigilationMaxDuties;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_exam_settings', { p_campus_id: campusId, p_settings: patch });
  if (error) return { error: datesheetError(error.message, error.details) };
  revalidatePath(PATH);
  return { error: null };
}
