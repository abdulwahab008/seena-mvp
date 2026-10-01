'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { karachiLocalToIso, ptmEventSchema, ptmSlotsSchema, type PtmEventInput, type PtmSlotsInput } from '@/lib/validation';

type Result = { error: string | null; count?: number };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only the Principal can set up a PTM.';
  if (message.includes('END_BEFORE_START')) return 'The end time must be after the start time.';
  if (message.includes('TEACHER_NOT_FOUND')) return 'One of the teachers could not be found.';
  if (message.includes('chk_ptm_window')) return 'Booking must open before it closes.';
  return 'Something went wrong. Please try again.';
}

export async function createEvent(campusId: string, input: PtmEventInput): Promise<Result> {
  const e = ptmEventSchema.safeParse(input);
  if (!z.string().uuid().safeParse(campusId).success || !e.success) return { error: e.success ? 'Invalid campus.' : (e.error.issues[0]?.message ?? 'Invalid input.') };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_ptm_event', {
    p_campus_id: campusId,
    p_title: e.data.title,
    p_event_date: e.data.eventDate,
    p_start_time: e.data.startTime,
    p_cutoff_hours: e.data.cutoffHours,
    p_opens_at: karachiLocalToIso(e.data.opensAt || undefined),
    p_slot_minutes: e.data.slotMinutes,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/ptm');
  return { error: null };
}

export async function generateSlots(input: PtmSlotsInput): Promise<Result> {
  const s = ptmSlotsSchema.safeParse(input);
  if (!s.success) return { error: s.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('generate_ptm_slots', { p_event_id: s.data.eventId, p_teacher_ids: s.data.teacherIds, p_start_time: s.data.startTime, p_end_time: s.data.endTime });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/ptm');
  return { error: null, count: data as number };
}
