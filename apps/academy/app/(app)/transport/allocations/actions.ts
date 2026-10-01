'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { allocateTransportSchema, postTransportChargesSchema, transportProrateSchema, transportWaitlistSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, todayPk, type ActionResult, type LooseClient } from '@/lib/transport/rpc';

const MESSAGES = {
  ROUTE_FULL: 'Route full: no seats left. Add the student to the waiting list below.',
  ROUTE_NO_VEHICLE: 'No vehicle is assigned to this route on that date, so seats cannot be counted.',
  ROUTE_INACTIVE: 'This route is inactive.',
  ALLOCATION_OVERLAP: 'The student already has a bus allocation overlapping these dates.',
  ALLOCATION_NOT_FOUND: 'No current allocation was found for this student.',
  ALLOCATION_NOT_OPEN: 'That allocation has already ended.',
  NO_ACTIVE_ENROLMENT: 'The student has no active enrolment.',
  STOP_NOT_FOUND: 'A selected stop was not found on the student\'s campus.',
  STOPS_ON_DIFFERENT_ROUTES: 'Pickup and drop stops must be on the same route.',
  STOP_HAS_NO_FARE: 'The pickup stop has no fare slab. Set one on the route first.',
  STUDENT_NOT_FOUND: 'Student not found.',
  SETTING_INVALID: 'That setting value is not valid.',
};

async function studentByGr(supabase: LooseClient, gr: string): Promise<string | null> {
  const { data } = await supabase.from('student').select('id').eq('gr_number', gr).is('deleted_at', null).maybeSingle();
  return (data as { id: string } | null)?.id ?? null;
}

export async function allocateStudent(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(allocateTransportSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const studentId = await studentByGr(supabase, p.data.grNumber);
  if (!studentId) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('allocate_transport', { p_student_id: studentId, p_pickup_stop: p.data.pickupStopId, p_drop_stop: p.data.dropStopId ?? p.data.pickupStopId, p_from: p.data.from });
  if (error) return { error: rpcError(error.message, MESSAGES) + (error.message.includes('ROUTE_FULL') ? ` (${/ROUTE_FULL \((\d+\/\d+)\)/.exec(error.message)?.[1] ?? ''})` : '') };
  revalidatePath('/transport/allocations');
  return { error: null, message: 'Student allocated. The transport fee follows from the stop.' };
}

export async function moveStudent(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(allocateTransportSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const studentId = await studentByGr(supabase, p.data.grNumber);
  if (!studentId) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('move_transport_allocation', { p_student_id: studentId, p_pickup_stop: p.data.pickupStopId, p_drop_stop: p.data.dropStopId ?? p.data.pickupStopId, p_from: p.data.from });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/allocations');
  return { error: null, message: 'Stop changed. The month\'s fee was split between the two stops.' };
}

export async function joinWaitlist(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(transportWaitlistSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const studentId = await studentByGr(supabase, p.data.grNumber);
  if (!studentId) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('join_transport_waitlist', { p_student_id: studentId, p_route_id: p.data.routeId });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/allocations');
  return { error: null, message: 'Added to the waiting list.' };
}

export async function endAllocation(allocationId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(allocationId).success) return { error: 'Invalid allocation.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('end_transport_allocation', { p_allocation_id: allocationId, p_last_day: todayPk() });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/allocations');
  return { error: null, message: 'Service ended today.' };
}

export async function setProratePolicy(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(transportProrateSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('set_transport_setting', { p_key: 'transport.prorate', p_value: p.data.mode });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/allocations');
  return { error: null, message: 'Policy saved.' };
}

export async function postCharges(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(postTransportChargesSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('post_transport_charges', { p_month: p.data.month });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/allocations');
  return { error: null, message: `${data ?? 0} ledger line(s) posted.` };
}
