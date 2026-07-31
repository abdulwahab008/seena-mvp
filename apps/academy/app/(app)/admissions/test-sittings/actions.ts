'use server';

import { revalidatePath } from 'next/cache';
import { createTestSittingSchema, allocateTestSeatSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

// FR-B11: schedule an admission test sitting. Role, tenant, and capacity
// checks are enforced inside create_test_sitting() itself.
export async function createTestSitting(campusId: string, sessionId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = createTestSittingSchema.safeParse({
    campusId,
    sessionId,
    classLevelId: formData.get('classLevelId'),
    startsAt: formData.get('startsAt'),
    capacity: formData.get('capacity'),
    venue: formData.get('venue') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_test_sitting', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
    p_class_level_id: parsed.data.classLevelId,
    p_starts_at: parsed.data.startsAt,
    p_capacity: parsed.data.capacity,
    p_venue: parsed.data.venue,
  });
  if (error) {
    if (error.message.includes('CAPACITY_MUST_BE_POSITIVE')) return { error: 'Capacity must be at least 1.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to schedule a test sitting.' };
    return { error: 'Could not schedule the sitting.' };
  }

  revalidatePath('/admissions/test-sittings');
  return { error: null };
}

export type AllocateState = { error: string | null; seatNo: number | null };

// FR-B11: allocate (or reallocate) a candidate's seat at a sitting.
// Capacity and the one-active-allocation-per-application rule are enforced
// inside fn_allocate_test_seat() itself.
export async function allocateTestSeat(_prev: AllocateState, formData: FormData): Promise<AllocateState> {
  const parsed = allocateTestSeatSchema.safeParse({
    sittingId: formData.get('sittingId'),
    applicationId: formData.get('applicationId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', seatNo: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_allocate_test_seat', {
    p_sitting_id: parsed.data.sittingId,
    p_application_id: parsed.data.applicationId,
  });
  if (error) {
    if (error.message.includes('SITTING_FULL')) return { error: 'This sitting is full.', seatNo: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to allocate a seat.', seatNo: null };
    return { error: 'Could not allocate a seat.', seatNo: null };
  }

  revalidatePath('/admissions/test-sittings');
  return { error: null, seatNo: data as number };
}

export type RollSlipCandidate = { seat_no: number; application_no: string | null; child_name: string };
export type RollSlipPayload = { sitting_id: string; venue: string | null; starts_at: string; capacity: number; candidates: RollSlipCandidate[] };

export async function fetchRollSlip(sittingId: string): Promise<{ error: string | null; payload: RollSlipPayload | null }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_build_roll_slip_payload', { p_sitting_id: sittingId });
  if (error) return { error: 'Could not load the roll slip.', payload: null };
  return { error: null, payload: data as RollSlipPayload };
}
