'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

/**
 * FR-I09. exam_seat_allocation has a SELECT policy and no write policy: a plan
 * only ever changes through fn_generate_seating_plan().
 */
const PATH = '/exams/seating';
type Result = { error: string | null };

function seatingError(message: string, details?: string | null): string {
  const shortfall = /capacity_shortfall: (\d+)/.exec(message);
  if (shortfall) return `Not enough seats: ${shortfall[1]} short. ${details ?? ''}`.trim();
  if (message.includes('SLOT_HALL_REQUIRED')) return 'Assign a hall to this paper on the datesheet first.';
  if (message.includes('STRATEGY_INVALID')) return 'Unknown seating strategy.';
  if (message.includes('SET_COUNT_INVALID')) return 'A paper is printed in 1 to 4 sets.';
  if (message.includes('HALL_SEATS_IN_USE')) return 'Seats that are allocated cannot be removed.';
  if (message.includes('SEAT_NOT_FOUND')) return 'That seat does not exist in the hall.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Could not complete that action.';
}

export type GenerateResult = { error: string | null; seated?: number; violations?: number };

export async function generatePlan(slotId: string, strategy: 'interleave' | 'sequential'): Promise<GenerateResult> {
  if (!z.string().uuid().safeParse(slotId).success) return { error: 'Invalid paper.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_generate_seating_plan', { p_slot_id: slotId, p_strategy: strategy });
  if (error) return { error: seatingError(error.message, error.details) };
  const { data: violations } = await supabase.rpc('fn_seating_violations', { p_slot_id: slotId });
  revalidatePath(PATH);
  return { error: null, seated: data ?? 0, violations: (violations ?? []).length };
}

export async function setPaperSets(examSubjectId: string, setCount: number): Promise<Result> {
  if (!z.string().uuid().safeParse(examSubjectId).success) return { error: 'Invalid paper.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_paper_set_group', { p_exam_subject_id: examSubjectId, p_set_count: setCount });
  if (error) return { error: seatingError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}

export async function setDeskAvailable(hallId: string, rowNo: number, seatNo: number, available: boolean): Promise<Result> {
  const p = z.object({ hallId: z.string().uuid(), rowNo: z.number().int().min(1), seatNo: z.number().int().min(1) }).safeParse({ hallId, rowNo, seatNo });
  if (!p.success) return { error: 'Enter a valid row and seat.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_hall_seat_available', { p_hall_id: hallId, p_row_no: rowNo, p_seat_no: seatNo, p_available: available });
  if (error) return { error: seatingError(error.message) };
  revalidatePath(PATH);
  return { error: null };
}
