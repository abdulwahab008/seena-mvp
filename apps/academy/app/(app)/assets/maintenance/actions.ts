'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, toPaisa, type ActionError } from '@/lib/rpc-action';
import { capitalisationThresholdSchema, maintenanceSchema, vendorSchema } from '@/lib/validation';

const MESSAGES: [string, string][] = [
  ['BELOW_CAPITALISATION_THRESHOLD', 'This repair is not above the capitalisation threshold, so it cannot be added to the asset\'s cost. Log it as an expense.'],
  ['ASSET_NOT_AVAILABLE', 'This asset has been disposed of.'],
  ['DOWNTIME_INVALID', 'Downtime must end on or after it starts.'],
  ['VENDOR_EXISTS', 'A vendor with this name already exists.'],
  ['VENDOR_NOT_FOUND', 'That vendor was not found.'],
  ['MAINTENANCE_ALREADY_CLOSED', 'This repair is already closed.'],
  ['FORBIDDEN', 'You do not have permission to log maintenance for this asset.'],
];
const first = (e: { issues: { message: string }[] } | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

export async function logMaintenanceAction(input: Record<string, string>): Promise<ActionError> {
  const p = maintenanceSchema.safeParse({ ...input, isCapitalised: input.isCapitalised === 'true' });
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('log_asset_maintenance', {
    p_asset_id: p.data.assetId,
    p_fault: p.data.fault,
    p_reported_on: p.data.reportedOn || undefined,
    p_vendor_id: p.data.vendorId || undefined,
    p_cost: toPaisa(p.data.costPkr),
    p_is_capitalised: p.data.isCapitalised,
    p_downtime_from: p.data.downtimeFrom || undefined,
    p_downtime_to: p.data.downtimeTo || undefined,
    p_next_service_due: p.data.nextServiceDue || undefined,
    p_responsible_user_id: p.data.responsibleUserId || undefined,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/maintenance');
  revalidatePath('/assets');
  return { error: null };
}

export async function closeMaintenanceAction(maintenanceId: string): Promise<ActionError> {
  if (!z.string().uuid().safeParse(maintenanceId).success) return { error: 'Invalid repair.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('close_asset_maintenance', { p_maintenance_id: maintenanceId });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/maintenance');
  revalidatePath('/assets');
  return { error: null };
}

export async function createVendorAction(input: Record<string, string>): Promise<ActionError> {
  const p = vendorSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_procurement_vendor', { p_name: p.data.name, p_phone: p.data.phone || undefined });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/maintenance');
  return { error: null };
}

export async function setThresholdAction(input: Record<string, string>): Promise<ActionError> {
  const p = capitalisationThresholdSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_capitalisation_threshold', { p_threshold_paisa: toPaisa(p.data.thresholdPkr) });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets/maintenance');
  return { error: null };
}
