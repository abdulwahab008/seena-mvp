'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { transportCrewSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  DUPLICATE_CNIC: 'A crew member with this CNIC already exists (DUPLICATE_CNIC).',
  CNIC_INVALID: 'CNIC must be 13 digits.',
  LICENCE_REQUIRED: 'A driver needs a licence number, class and expiry date.',
  STAFF_NOT_FOUND: 'That staff record was not found.',
};

export async function saveCrew(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(transportCrewSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('save_transport_crew', {
    p_campus_id: p.data.campusId, p_full_name: p.data.fullName, p_cnic: p.data.cnic, p_crew_role: p.data.crewRole, p_phone: p.data.phone,
    p_licence_no: p.data.licenceNo, p_licence_class: p.data.licenceClass, p_licence_expires_on: p.data.licenceExpiresOn,
    p_police_verified_on: p.data.policeVerifiedOn, p_blood_group: p.data.bloodGroup,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/crew');
  return { error: null, message: 'Crew member saved.' };
}
