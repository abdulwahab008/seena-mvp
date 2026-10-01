'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { fareSlabSchema, transportRouteSchema, transportStopSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, rupeesToPaisa, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  ROUTE_CODE_EXISTS: 'A route with this code already exists on this campus.',
  ROUTE_NOT_FOUND: 'That route no longer exists.',
  STOP_NOT_FOUND: 'That stop no longer exists.',
  SLAB_NOT_FOUND: 'That fare slab was not found on this campus.',
  STOP_IN_USE: 'Students are allocated to this stop, so it cannot be removed.',
  AMOUNT_MUST_BE_POSITIVE: 'The fare must be above zero.',
};

export async function createRoute(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(transportRouteSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('save_transport_route', {
    p_campus_id: p.data.campusId, p_code: p.data.code, p_name: p.data.name, p_shift: p.data.shift, p_active: p.data.active,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/routes');
  return { error: null, message: 'Route saved.' };
}

export async function saveFareSlab(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(fareSlabSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('save_fare_slab', {
    p_campus_id: p.data.campusId, p_code: p.data.code, p_name: p.data.name,
    p_monthly_amount_paisa: rupeesToPaisa(p.data.amount), p_effective_from: p.data.effectiveFrom,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/routes');
  return { error: null, message: 'Fare slab saved. Every student on it re-prices from the effective date.' };
}

export async function addStop(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(transportStopSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('add_transport_stop', {
    p_route_id: p.data.routeId, p_name: p.data.name, p_name_ur: p.data.nameUr, p_lat: p.data.lat, p_lng: p.data.lng,
    p_pickup_time: p.data.pickupTime, p_drop_time: p.data.dropTime, p_fare_slab_id: p.data.fareSlabId,
    p_seq: p.data.seq === undefined ? undefined : Math.trunc(p.data.seq),
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath(`/transport/routes/${p.data.routeId}`);
  return { error: null, message: 'Stop added.' };
}

export async function moveStop(routeId: string, stopId: string, newSeq: number): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(stopId).success || !Number.isInteger(newSeq) || newSeq < 1) return { error: 'Invalid stop.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('move_transport_stop', { p_stop_id: stopId, p_new_seq: newSeq });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath(`/transport/routes/${routeId}`);
  return { error: null };
}

export async function removeStop(routeId: string, stopId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(stopId).success) return { error: 'Invalid stop.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('remove_transport_stop', { p_stop_id: stopId });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath(`/transport/routes/${routeId}`);
  return { error: null, message: 'Stop removed.' };
}
