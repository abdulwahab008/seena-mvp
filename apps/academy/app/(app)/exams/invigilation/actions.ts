'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { invigilationError } from '@/lib/exams/invigilation-errors';
import { invigilationDutySchema, invigilationExclusionSchema, type InvigilationDutyInput, type InvigilationExclusionInput } from '@/lib/validation';

/**
 * FR-I10. The roster is written only through assign_invigilation(),
 * add_invigilation_duty(), remove_invigilation_duty() and the exclusion
 * functions; the tables have a SELECT policy and no write policy.
 */
const PATH = '/exams/invigilation';
type Result = { error: string | null };

export type UnderstaffedSlot = { slot_id: string; required: number; assigned: number; shortfall: number; pool: Record<string, number> };
export type AssignReport = {
  assigned_now: number;
  substitution_tasks: number;
  understaffed: UnderstaffedSlot[];
  spread: { min: number; max: number };
};
export type AssignResult = { error: string | null; report?: AssignReport };

export async function runAssignment(datesheetId: string): Promise<AssignResult> {
  if (!z.string().uuid().safeParse(datesheetId).success) return { error: 'Invalid datesheet.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('assign_invigilation', { p_datesheet_id: datesheetId });
  if (error) return { error: invigilationError(error.message) };
  revalidatePath(PATH);
  return { error: null, report: data as unknown as AssignReport };
}

export async function addDuty(input: InvigilationDutyInput): Promise<Result> {
  const p = invigilationDutySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_invigilation_duty', { p_slot_id: p.data.slotId, p_staff_user_id: p.data.staffUserId });
  if (error) return { error: invigilationError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function removeDuty(dutyId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(dutyId).success) return { error: 'Invalid duty.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_invigilation_duty', { p_duty_id: dutyId });
  if (error) return { error: invigilationError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function addExclusion(input: InvigilationExclusionInput): Promise<Result> {
  const p = invigilationExclusionSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_invigilation_exclusion', {
    p_exam_term_id: p.data.examTermId,
    p_staff_user_id: p.data.staffUserId,
    p_date: p.data.date,
    p_reason: p.data.reason,
  });
  if (error) return { error: invigilationError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function removeExclusion(id: string): Promise<Result> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid exclusion.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_invigilation_exclusion', { p_id: id });
  if (error) return { error: invigilationError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function notifyRoster(datesheetId: string): Promise<Result & { notified?: number }> {
  if (!z.string().uuid().safeParse(datesheetId).success) return { error: 'Invalid datesheet.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('notify_duty_roster', { p_datesheet_id: datesheetId });
  if (error) return { error: invigilationError(error.message) };
  revalidatePath(PATH);
  return { error: null, notified: data ?? 0 };
}
