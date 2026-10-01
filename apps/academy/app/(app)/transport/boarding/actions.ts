'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { boardingBatchSchema, openLegSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, todayPk, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  NO_ASSIGNMENT: 'No vehicle and crew are assigned to this route today.',
  LEG_NOT_FOUND: 'That trip was not found.',
  BATCH_TOO_LARGE: 'The batch is too large.',
};

export async function openLeg(values: Record<string, string>): Promise<ActionResult & { legId?: string }> {
  const p = parseValues(openLegSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('open_trip_leg', { p_route_id: p.data.routeId, p_date: todayPk(), p_leg_type: p.data.legType });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  return { error: null, legId: data as string };
}

/** One batched RPC per leg. Safe to call again with the same events (idempotent on device_event_id). */
export async function syncBoarding(events: unknown): Promise<ActionResult & { counts?: Record<string, number> }> {
  const p = parseValues(boardingBatchSchema, events);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('sync_boarding_batch', { p_events: p.data });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/boarding');
  return { error: null, counts: data as Record<string, number> };
}

export async function completeLeg(legId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(legId).success) return { error: 'Invalid trip.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('complete_trip_leg', { p_leg_id: legId });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/boarding');
  return { error: null, message: 'Trip marked complete.' };
}
