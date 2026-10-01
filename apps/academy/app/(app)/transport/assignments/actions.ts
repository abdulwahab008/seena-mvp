'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { assignTripSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  LICENCE_CLASS_INSUFFICIENT: 'The driver\'s licence class does not cover this vehicle (LICENCE_CLASS_INSUFFICIENT).',
  LICENCE_EXPIRED: 'The driver\'s licence is expired on the trip dates (LICENCE_EXPIRED).',
  NOT_A_DRIVER: 'The selected crew member is not a driver.',
  CREW_INACTIVE: 'The selected crew member is inactive.',
  ASSIGNMENT_CONFLICT: 'The route, vehicle or driver is already assigned for part of those dates.',
  REASON_MIN_LENGTH_10: 'Give an override reason of at least 10 characters.',
  CONDUCTOR_INVALID: 'The conductor must be a conductor on this campus.',
  ATTENDANT_INVALID: 'The attendant must be an attendant on this campus.',
  SPAN_INVALID: 'The end date cannot be before the start date.',
  ROUTE_NOT_FOUND: 'That route was not found.',
  VEHICLE_NOT_FOUND: 'That vehicle was not found on this campus.',
  CREW_NOT_FOUND: 'That crew member was not found on this campus.',
};

export async function assignTrip(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(assignTripSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('assign_transport_trip', {
    p_route_id: p.data.routeId, p_vehicle_id: p.data.vehicleId, p_driver_id: p.data.driverId, p_from: p.data.from, p_to: p.data.to,
    p_conductor_id: p.data.conductorId, p_attendant_id: p.data.attendantId, p_override_reason: p.data.overrideReason,
  });
  if (error) {
    const blocked = /VEHICLE_BLOCKED: (.*)/.exec(error.message);
    if (blocked) return { error: `Vehicle blocked: ${blocked[1]}. A Principal can override with a reason.` };
    return { error: rpcError(error.message, MESSAGES) };
  }
  revalidatePath('/transport/assignments');
  const warning = (data as { warning?: string | null } | null)?.warning;
  return { error: null, message: warning ? `Assigned. Warning: ${warning.replaceAll('_', ' ').toLowerCase()}.` : 'Assigned.' };
}
