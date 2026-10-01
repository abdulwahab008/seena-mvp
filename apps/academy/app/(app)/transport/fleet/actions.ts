'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { tokenTaxSettingSchema, transportVehicleSchema, vehicleDocumentSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  VEHICLE_REG_EXISTS: 'A vehicle with this registration already exists.',
  VEHICLE_NOT_FOUND: 'That vehicle was not found.',
  FILE_PATH_INVALID: 'The uploaded file path is not valid for this school.',
  SETTING_INVALID: 'That setting value is not valid.',
};

export async function saveVehicle(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(transportVehicleSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('save_transport_vehicle', {
    p_campus_id: p.data.campusId, p_reg_no: p.data.regNo, p_seat_capacity: p.data.seatCapacity, p_make: p.data.make, p_model: p.data.model,
    p_fuel: p.data.fuel, p_ownership: p.data.ownership, p_active: p.data.active,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/fleet');
  return { error: null, message: 'Vehicle saved.' };
}

export async function addDocument(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(vehicleDocumentSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('add_vehicle_document', {
    p_vehicle_id: p.data.vehicleId, p_doc_type: p.data.docType, p_expires_on: p.data.expiresOn, p_doc_no: p.data.docNo,
    p_issued_on: p.data.issuedOn, p_file_path: p.data.filePath, p_mandatory: p.data.mandatory,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/fleet');
  return { error: null, message: 'Document recorded.' };
}

export async function setTokenTaxPolicy(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(tokenTaxSettingSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('set_transport_setting', { p_key: 'transport.token_tax_mandatory_for_contracted', p_value: p.data.mandatory });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/transport/fleet');
  return { error: null, message: 'Policy saved.' };
}
