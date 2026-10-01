'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { hostelAllocateSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, todayPk, type ActionResult, type LooseClient } from '@/lib/transport/rpc';

const MESSAGES = {
  BED_TAKEN: 'That bed is already taken for those dates (BED_TAKEN).',
  STUDENT_ALREADY_HOUSED: 'This student already has a bed for those dates.',
  GENDER_MISMATCH: 'This block is for the other gender (GENDER_MISMATCH).',
  ROOM_OUT_OF_SERVICE: 'That room is out of service for new stays.',
  BED_RETIRED: 'That bed has been retired.',
  NO_ACTIVE_ENROLMENT: 'The student has no active enrolment on this campus.',
  ALLOCATION_NOT_FOUND: 'The student has no current hostel stay.',
  ALLOCATION_NOT_OPEN: 'That stay has already ended.',
  SAME_BED: 'The student is already in that bed.',
  SPAN_INVALID: 'The end date cannot be before the start date.',
  BED_NOT_FOUND: 'No bed has that code.',
};

async function lookup(supabase: LooseClient, gr: string, bedCode: string): Promise<{ studentId: string; bedId: string } | { error: string }> {
  const [{ data: s }, { data: b }] = await Promise.all([
    supabase.from('student').select('id').eq('gr_number', gr).is('deleted_at', null).maybeSingle(),
    supabase.from('hostel_bed').select('id').eq('bed_code', bedCode).maybeSingle(),
  ]);
  if (!s) return { error: 'No student has that GR number.' };
  if (!b) return { error: 'No bed has that code.' };
  return { studentId: (s as { id: string }).id, bedId: (b as { id: string }).id };
}

export async function allocateBed(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelAllocateSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const found = await lookup(supabase, p.data.grNumber, p.data.bedCode);
  if ('error' in found) return found;
  const { error } = await supabase.rpc('allocate_bed', { p_student_id: found.studentId, p_bed_id: found.bedId, p_from: p.data.from, p_to: p.data.to });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/allocations');
  return { error: null, message: `Bed ${p.data.bedCode} allocated.` };
}

export async function transferBed(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelAllocateSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const found = await lookup(supabase, p.data.grNumber, p.data.bedCode);
  if ('error' in found) return found;
  const { error } = await supabase.rpc('transfer_bed', { p_student_id: found.studentId, p_to_bed_id: found.bedId, p_from: p.data.from, p_reason: p.data.reason });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/allocations');
  return { error: null, message: `Transferred to ${p.data.bedCode}.` };
}

export async function vacate(allocationId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(allocationId).success) return { error: 'Invalid stay.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('vacate_bed', { p_allocation_id: allocationId, p_last_day: todayPk(), p_reason: 'Vacated by hostel staff' });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/allocations');
  return { error: null, message: 'Stay ended. The bed is free from tomorrow.' };
}
