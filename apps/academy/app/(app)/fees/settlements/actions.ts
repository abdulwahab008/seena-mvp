'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { disburseSettlementSchema, proposeSettlementSchema, type DisburseSettlementInput, type ProposeSettlementInput } from '@/lib/validation';

const previewSchema = z.object({
  ledger_balance_paisa: z.number(),
  credit_adjustment_paisa: z.number(),
  net_refund_paisa: z.number(),
  remaining_dues_paisa: z.number(),
});

function mapError(message: string): string {
  const known: [string, string][] = [
    ['ENROLMENT_NOT_FOUND', 'No active enrolment found for that GR number.'],
    ['SETTLEMENT_ALREADY_OPEN', 'This student already has a settlement awaiting approval or disbursement.'],
    ['CANNOT_APPROVE_OWN_PROPOSAL', 'You cannot approve a settlement you proposed.'],
    ['OWNER_APPROVAL_NOT_REQUIRED', 'This settlement is under the threshold — the Principal decides it.'],
    ['SETTLEMENT_NOT_APPROVED', 'This settlement is not fully approved yet.'],
    ['LEDGER_MOVED_SINCE_PROPOSAL', 'The student\'s account changed since this was proposed. Reject it and propose again.'],
    ['INSTRUMENT_REFERENCE_REQUIRED', 'A cheque or transfer needs its reference number.'],
    ['ALREADY_DECIDED', 'You already decided this settlement.'],
    ['FORBIDDEN', 'You do not have permission for this step.'],
  ];
  return known.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
}

async function enrolmentForGr(grNumber: string): Promise<string | null> {
  const supabase = await supabaseServer();
  const { data } = await supabase.from('student').select('id').eq('gr_number', grNumber).maybeSingle();
  if (!data) return null;
  const { data: enrol } = await supabase.from('enrolment').select('id').eq('student_id', data.id).eq('status', 'active').maybeSingle();
  return enrol?.id ?? null;
}

export type PreviewResult = { error: string } | { error: null; preview: z.infer<typeof previewSchema> };

export async function previewSettlement(input: ProposeSettlementInput): Promise<PreviewResult> {
  const parsed = proposeSettlementSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const enrolId = await enrolmentForGr(parsed.data.grNumber);
  if (!enrolId) return { error: mapError('ENROLMENT_NOT_FOUND') };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('compute_withdrawal_settlement', { p_enrolment_id: enrolId, p_leaving_date: parsed.data.leavingDate, p_basis: parsed.data.basis });
  if (error) return { error: mapError(error.message) };
  return { error: null, preview: previewSchema.parse(data) };
}

export async function proposeSettlement(input: ProposeSettlementInput): Promise<{ error: string | null }> {
  const parsed = proposeSettlementSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const enrolId = await enrolmentForGr(parsed.data.grNumber);
  if (!enrolId) return { error: mapError('ENROLMENT_NOT_FOUND') };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('propose_fee_settlement', { p_enrolment_id: enrolId, p_leaving_date: parsed.data.leavingDate, p_basis: parsed.data.basis, p_note: parsed.data.note });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/settlements');
  return { error: null };
}

export async function decideSettlement(settlementId: string, approve: boolean): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(settlementId).success) return { error: 'Invalid settlement.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_fee_settlement', { p_settlement_id: settlementId, p_approve: approve });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/settlements');
  return { error: null };
}

export async function disburseSettlement(input: DisburseSettlementInput): Promise<{ error: string | null }> {
  const parsed = disburseSettlementSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('disburse_fee_settlement', { p_settlement_id: parsed.data.settlementId, p_instrument_type: parsed.data.instrumentType, p_instrument_ref: parsed.data.instrumentRef });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/settlements');
  return { error: null };
}
