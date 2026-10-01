'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, toPaisa, type ActionError } from '@/lib/rpc-action';
import { assetDisposalSchema, assetSchema, depreciationRunSchema } from '@/lib/validation';

const MESSAGES: [string, string][] = [
  ['ASSET_TAG_EXISTS', 'An asset with this tag number already exists.'],
  ['RATE_REQUIRED', 'Reducing balance needs an annual rate.'],
  ['SALVAGE_INVALID', 'Salvage value cannot exceed the cost.'],
  ['VEHICLE_NOT_FOUND', 'That vehicle was not found in the fleet.'],
  ['ASSET_ALREADY_DISPOSED', 'This asset has already been disposed.'],
  ['DISPOSAL_BEFORE_POSTED_PERIOD', 'Depreciation has already been posted beyond that month.'],
  ['DISPOSAL_DATE_INVALID', 'The disposal date cannot be before the purchase date.'],
  ['PROCEEDS_INVALID', 'A write-off has no sale proceeds.'],
  ['FORBIDDEN', 'You do not have permission for this asset.'],
];
const first = (e: { issues: { message: string }[] } | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

export async function createAssetAction(input: Record<string, string>): Promise<ActionError> {
  const p = assetSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_asset', {
    p_campus_id: p.data.campusId,
    p_tag_no: p.data.tagNo,
    p_name: p.data.name,
    p_category: p.data.category,
    p_purchased_on: p.data.purchasedOn,
    p_capitalised_cost: toPaisa(p.data.costPkr),
    p_useful_life_months: p.data.lifeMonths,
    p_salvage_value: toPaisa(p.data.salvagePkr),
    p_method: p.data.method,
    p_rate: typeof p.data.rate === 'number' ? p.data.rate : undefined,
    p_vehicle_id: p.data.vehicleId || undefined,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets');
  return { error: null };
}

export async function runDepreciationAction(input: Record<string, string>): Promise<ActionError & { message?: string }> {
  const p = depreciationRunSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const period = p.data.period.length === 7 ? `${p.data.period}-01` : p.data.period;
  const { data, error } = await supabase.rpc('run_monthly_depreciation', { p_period: period });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets');
  const r = data as { status: string; posted: number };
  return { error: null, message: r.status === 'ALREADY_POSTED' ? 'ALREADY_POSTED: this period was already run, nothing was posted.' : `Posted ${r.posted} depreciation entries.` };
}

export async function disposeAssetAction(input: Record<string, string>): Promise<ActionError> {
  const p = assetDisposalSchema.safeParse({ ...input, writeOff: input.writeOff === 'true' });
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('dispose_asset', {
    p_asset_id: p.data.assetId,
    p_disposed_on: p.data.disposedOn,
    p_proceeds: toPaisa(p.data.proceedsPkr),
    p_write_off: p.data.writeOff,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/assets');
  return { error: null };
}
