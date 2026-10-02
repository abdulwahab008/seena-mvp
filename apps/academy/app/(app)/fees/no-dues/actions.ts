'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import {
  decisionReasonSchema,
  disburseDepositSchema,
  noDuesItemSchema,
  recordDepositSchema,
  startClearanceSchema,
  type DisburseDepositInput,
  type NoDuesItemInput,
  type RecordDepositInput,
  type StartClearanceInput,
} from '@/lib/validation';

type Result = { error: string | null };

const MESSAGES: [string, string][] = [
  ['ENROLMENT_NOT_FOUND', 'No active enrolment found for that GR number.'],
  ['DEPOSIT_ALREADY_HELD', 'This student already has a deposit on hold.'],
  ['NO_DEPOSIT_HELD', 'No deposit is held for this student.'],
  ['NO_DEPOSIT_AVAILABLE', 'There is no deposit available to net against.'],
  ['NOTHING_TO_NET', 'There is nothing left to net.'],
  ['OUTSTANDING_AMOUNT_REMAINS', 'An amount is still outstanding. Collect it, net it against the deposit, or waive it with a reason.'],
  ['FEES_ITEM_IS_COMPUTED', 'Fee dues come from the ledger and cannot be typed in.'],
  ['NO_DUES_NOT_CLEARED', 'Every checklist item must be cleared or waived before the refund can be approved.'],
  ['CANNOT_APPROVE_OWN_REQUEST', 'You cannot approve a clearance you requested.'],
  ['REFUND_NOT_APPROVED', 'The refund has not been approved yet.'],
  ['LEDGER_MOVED_SINCE_APPROVAL', 'The fee dues changed after the clearance. Rebuild the checklist.'],
  ['CLEARANCE_NOT_OPEN', 'This clearance is no longer open.'],
  ['REASON_MIN_LENGTH_20', 'Give a reason of at least 20 characters.'],
  ['INSTRUMENT_REFERENCE_REQUIRED', 'A cheque or transfer needs its reference number.'],
  ['FORBIDDEN', 'You do not have permission for this step.'],
];
const mapError = (message: string) => MESSAGES.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
const toPaisa = (pkr: number) => Math.round(pkr * 100);
const first = (z_: { error: z.ZodError | undefined }) => z_.error?.issues[0]?.message ?? 'Invalid input.';

async function enrolmentForGr(grNumber: string): Promise<string | null> {
  const supabase = await supabaseServer();
  const { data } = await supabase.from('student').select('id').eq('gr_number', grNumber).maybeSingle();
  if (!data) return null;
  const { data: enrol } = await supabase.from('enrolment').select('id').eq('student_id', data.id).eq('status', 'active').maybeSingle();
  return enrol?.id ?? null;
}

async function run(fn: (supabase: Awaited<ReturnType<typeof supabaseServer>>) => PromiseLike<{ error: { message: string } | null }>): Promise<Result> {
  const supabase = await supabaseServer();
  const { error } = await fn(supabase);
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/no-dues');
  return { error: null };
}

export async function startClearance(input: StartClearanceInput): Promise<Result> {
  const p = startClearanceSchema.safeParse(input);
  if (!p.success) return { error: first(p) };
  const enrolmentId = await enrolmentForGr(p.data.grNumber);
  if (!enrolmentId) return { error: mapError('ENROLMENT_NOT_FOUND') };
  return run((s) => s.rpc('build_no_dues_checklist', { p_enrolment_id: enrolmentId }));
}

export async function recordDeposit(input: RecordDepositInput): Promise<Result> {
  const p = recordDepositSchema.safeParse(input);
  if (!p.success) return { error: first(p) };
  const enrolmentId = await enrolmentForGr(p.data.grNumber);
  if (!enrolmentId) return { error: mapError('ENROLMENT_NOT_FOUND') };
  return run((s) =>
    s.rpc('record_security_deposit', { p_enrolment_id: enrolmentId, p_amount_paisa: toPaisa(p.data.amountPkr), p_received_on: p.data.receivedOn, p_mode: p.data.mode, p_receipt_ref: p.data.receiptRef }),
  );
}

export async function setItemOutstanding(input: NoDuesItemInput): Promise<Result> {
  const p = noDuesItemSchema.safeParse(input);
  if (!p.success) return { error: first(p) };
  return run((s) => s.rpc('set_no_dues_item_outstanding', { p_item_id: p.data.itemId, p_outstanding_paisa: toPaisa(p.data.outstandingPkr), p_note: p.data.note }));
}

export async function clearItem(itemId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(itemId).success) return { error: 'Invalid item.' };
  return run((s) => s.rpc('clear_no_dues_item', { p_item_id: itemId }));
}

export async function netItem(itemId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(itemId).success) return { error: 'Invalid item.' };
  return run((s) => s.rpc('net_no_dues_item_against_deposit', { p_item_id: itemId }));
}

export async function waiveItem(itemId: string, reason: string): Promise<Result> {
  const p = decisionReasonSchema.safeParse({ reason });
  if (!p.success || !z.string().uuid().safeParse(itemId).success) return { error: p.success ? 'Invalid item.' : first(p) };
  return run((s) => s.rpc('waive_no_dues_item', { p_item_id: itemId, p_reason: p.data.reason }));
}

export async function overrideClearance(clearanceId: string, reason: string): Promise<Result> {
  const p = decisionReasonSchema.safeParse({ reason });
  if (!p.success || !z.string().uuid().safeParse(clearanceId).success) return { error: p.success ? 'Invalid clearance.' : first(p) };
  return run((s) => s.rpc('override_no_dues_clearance', { p_clearance_id: clearanceId, p_reason: p.data.reason }));
}

export async function approveRefund(enrolmentId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(enrolmentId).success) return { error: 'Invalid enrolment.' };
  return run((s) => s.rpc('approve_deposit_refund', { p_enrolment_id: enrolmentId }));
}

export async function disburseRefund(input: DisburseDepositInput): Promise<Result> {
  const p = disburseDepositSchema.safeParse(input);
  if (!p.success) return { error: first(p) };
  return run((s) => s.rpc('disburse_deposit_refund', { p_enrolment_id: p.data.enrolmentId, p_instrument_type: p.data.instrumentType, p_instrument_ref: p.data.instrumentRef }));
}
