'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { houseMoveSchema, housePointsSchema, houseSchema, type HouseInput, type HouseMoveInput, type HousePointsInput } from '@/lib/validation';

type Result = { error: string | null };
export type AutoAssignResult = Result & { summary?: { assigned: number; siblingMatch: number; balanced: number; spread: number } };

function mapError(message: string): string {
  const known: [string, string][] = [
    ['FORBIDDEN', 'You are not allowed to do this for this campus.'],
    ['HOUSE_NAME_DUPLICATE', 'A house with this name already exists on this campus.'],
    ['HOUSE_IN_USE', 'This house has students or history and cannot be deleted.'],
    ['NO_HOUSES_DEFINED', 'Create at least one house before auto-assigning.'],
    ['EFFECTIVE_DATE_BEFORE_CURRENT_HOUSE', 'The move date must be after the day the student joined their current house.'],
    ['STUDENT_HAS_NO_HOUSE_ON_DATE', 'That student had no house on that date.'],
    ['STUDENT_NOT_FOUND', 'No student with that GR number on this campus.'],
  ];
  return known.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
}

async function studentByGr(supabase: Awaited<ReturnType<typeof supabaseServer>>, gr: string) {
  const { data } = await supabase.from('student').select('id').eq('gr_number', gr).maybeSingle();
  return data?.id ?? null;
}

export async function createHouse(campusId: string, input: HouseInput): Promise<Result> {
  const h = houseSchema.safeParse(input);
  if (!z.string().uuid().safeParse(campusId).success || !h.success) return { error: h.success ? 'Invalid campus.' : (h.error.issues[0]?.message ?? 'Invalid input.') };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_house', { p_campus_id: campusId, p_name: h.data.name, p_colour_hex: h.data.colourHex, p_motto: h.data.motto || undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/houses');
  return { error: null };
}

export async function deleteHouse(houseId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(houseId).success) return { error: 'Invalid house.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_house', { p_house_id: houseId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/houses');
  return { error: null };
}

export async function setBalancing(campusId: string, enabled: boolean): Promise<Result> {
  if (!z.string().uuid().safeParse(campusId).success) return { error: 'Invalid campus.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_house_capacity_balancing', { p_campus_id: campusId, p_enabled: enabled });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/houses');
  return { error: null };
}

export async function autoAssign(campusId: string, sessionId: string): Promise<AutoAssignResult> {
  if (!z.string().uuid().safeParse(campusId).success || !z.string().uuid().safeParse(sessionId).success) return { error: 'Invalid selection.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('auto_assign_houses', { p_campus_id: campusId, p_session_id: sessionId });
  if (error) return { error: mapError(error.message) };
  const r = data as { assigned: number; sibling_match: number; balanced: number; spread: number };
  revalidatePath('/houses');
  return { error: null, summary: { assigned: r.assigned, siblingMatch: r.sibling_match, balanced: r.balanced, spread: r.spread } };
}

export async function moveStudent(input: HouseMoveInput): Promise<Result> {
  const m = houseMoveSchema.safeParse(input);
  if (!m.success) return { error: m.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const studentId = await studentByGr(supabase, m.data.grNumber);
  if (!studentId) return { error: mapError('STUDENT_NOT_FOUND') };
  const { error } = await supabase.rpc('set_student_house', { p_student_id: studentId, p_house_id: m.data.houseId, p_effective_date: m.data.effectiveDate });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/houses');
  return { error: null };
}

export async function awardPoints(input: HousePointsInput): Promise<Result> {
  const p = housePointsSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const studentId = await studentByGr(supabase, p.data.grNumber);
  if (!studentId) return { error: mapError('STUDENT_NOT_FOUND') };
  const { error } = await supabase.rpc('award_house_points', { p_student_id: studentId, p_points: p.data.points, p_awarded_on: p.data.awardedOn, p_category: p.data.category, p_note: p.data.note || undefined });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/houses');
  return { error: null };
}
