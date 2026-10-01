'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { settlementLineSchema } from '@/lib/validation';
import { parseRupeesToPaisa } from '@/lib/settlements/statement';
import { supabaseServer } from '@/lib/supabase/server';

export type SettlementState = { error: string | null; message?: string | null };

function mapError(message: string): string {
  if (message.includes('NO_SALARY_ON_FILE')) return 'This person has no salary on a contract, so a settlement cannot be computed.';
  if (message.includes('SETTLEMENT_ALREADY_APPROVED')) return 'The statement is already approved. Revise it to make a corrected version.';
  if (message.includes('SETTLEMENT_IMMUTABLE')) return 'An approved statement cannot be changed.';
  if (message.includes('LINE_TYPE_COMPUTED')) return 'Salary, leave encashment and notice recovery are computed; they cannot be typed in.';
  if (message.includes('LINE_IS_COMPUTED')) return 'Computed lines cannot be removed. Recompute the draft instead.';
  if (message.includes('LINE_INVALID')) return 'Enter a positive amount; recoveries must be deductions.';
  if (message.includes('SETTLEMENT_NOT_REVISABLE')) return 'Only the latest approved statement can be revised.';
  if (message.includes('SETTLEMENT_NOT_PAYABLE')) return 'Only an approved, current statement can be marked paid.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  if (message.includes('EXIT_NOT_FOUND') || message.includes('SETTLEMENT_NOT_FOUND') || message.includes('LINE_NOT_FOUND')) return 'Record not found.';
  return 'Something went wrong. Please try again.';
}

function refresh(exitId: string) {
  revalidatePath(`/staff/exits/${exitId}/settlement`);
}

const exitIdOf = (formData: FormData) => z.string().uuid().safeParse(formData.get('exitId'));

export async function createDraft(_prev: SettlementState, formData: FormData): Promise<SettlementState> {
  const exitId = exitIdOf(formData);
  if (!exitId.success) return { error: 'Invalid exit.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_settlement_draft', { p_exit_id: exitId.data });
  if (error) return { error: mapError(error.message) };
  refresh(exitId.data);
  return { error: null, message: 'Settlement computed.' };
}

export async function addLine(_prev: SettlementState, formData: FormData): Promise<SettlementState> {
  const exitId = exitIdOf(formData);
  const p = settlementLineSchema.safeParse({
    settlementId: formData.get('settlementId'),
    lineType: formData.get('lineType'),
    description: formData.get('description'),
    amount: formData.get('amount'),
    sign: formData.get('sign'),
  });
  if (!exitId.success || !p.success) return { error: p.success ? 'Invalid exit.' : (p.error.issues[0]?.message ?? 'Invalid input.') };
  const paisa = parseRupeesToPaisa(p.data.amount);
  if (paisa === null) return { error: 'Enter the amount in rupees, for example 1500 or 1500.50.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_settlement_line', {
    p_settlement_id: p.data.settlementId,
    p_line_type: p.data.lineType,
    p_description: p.data.description,
    p_amount_paisa: paisa,
    p_sign: Number(p.data.sign),
  });
  if (error) return { error: mapError(error.message) };
  refresh(exitId.data);
  return { error: null, message: 'Line added.' };
}

export async function removeLine(_prev: SettlementState, formData: FormData): Promise<SettlementState> {
  const exitId = exitIdOf(formData);
  const lineId = z.string().uuid().safeParse(formData.get('lineId'));
  if (!exitId.success || !lineId.success) return { error: 'Invalid line.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_settlement_line', { p_line_id: lineId.data });
  if (error) return { error: mapError(error.message) };
  refresh(exitId.data);
  return { error: null, message: 'Line removed.' };
}

async function settlementAction(formData: FormData, rpc: 'approve_settlement' | 'mark_settlement_paid' | 'revise_settlement', ok: string): Promise<SettlementState> {
  const exitId = exitIdOf(formData);
  const id = z.string().uuid().safeParse(formData.get('settlementId'));
  if (!exitId.success || !id.success) return { error: 'Invalid statement.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc(rpc, { p_settlement_id: id.data });
  if (error) return { error: mapError(error.message) };
  refresh(exitId.data);
  return { error: null, message: ok };
}

export async function approve(_prev: SettlementState, formData: FormData) {
  return settlementAction(formData, 'approve_settlement', 'Approved. The statement is now frozen.');
}
export async function markPaid(_prev: SettlementState, formData: FormData) {
  return settlementAction(formData, 'mark_settlement_paid', 'Marked as paid.');
}
export async function revise(_prev: SettlementState, formData: FormData) {
  return settlementAction(formData, 'revise_settlement', 'A new draft version was created.');
}
