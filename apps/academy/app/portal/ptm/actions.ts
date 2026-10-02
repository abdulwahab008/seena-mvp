'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export type PtmSlot = { slot_id: string; teacher_id: string; teacher_name: string; starts_at: string; duration_min: number; available: boolean; mine: boolean };
export type BookResult = { ok: boolean; message: string | null; code?: string; slots?: PtmSlot[]; error?: string | null };

const id = z.string().uuid();

export async function bookSlot(slotId: string, studentId: string): Promise<BookResult> {
  if (!id.safeParse(slotId).success || !id.safeParse(studentId).success) return { ok: false, message: 'Invalid selection.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('book_ptm_slot', { p_slot_id: slotId, p_student_id: studentId });
  if (error) {
    if (error.message.includes('TEACHER_NOT_FOR_STUDENT') || error.message.includes('FORBIDDEN')) return { ok: false, message: 'You cannot book this slot for this child.' };
    return { ok: false, message: 'Something went wrong. Please try again.' };
  }
  const r = data as { ok: boolean; code?: string; message?: string; slots?: PtmSlot[] };
  revalidatePath('/portal/ptm');
  return { ok: r.ok, code: r.code, message: r.ok ? null : (r.message ?? 'Could not book this slot.'), slots: r.slots };
}

export async function cancelBooking(bookingId: string): Promise<{ error: string | null }> {
  if (!id.safeParse(bookingId).success) return { error: 'Invalid booking.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('cancel_ptm_booking', { p_booking_id: bookingId });
  if (error) return { error: 'Could not cancel this booking.' };
  revalidatePath('/portal/ptm');
  return { error: null };
}

export async function joinWaitlist(slotId: string, studentId: string): Promise<{ error: string | null }> {
  if (!id.safeParse(slotId).success || !id.safeParse(studentId).success) return { error: 'Invalid selection.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('join_ptm_waitlist', { p_slot_id: slotId, p_student_id: studentId });
  if (error) return { error: 'Could not join the waiting list.' };
  revalidatePath('/portal/ptm');
  return { error: null };
}
