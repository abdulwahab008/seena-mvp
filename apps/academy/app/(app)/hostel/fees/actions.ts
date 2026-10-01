'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { hostelDepositRefundSchema, hostelTariffSchema, postHostelChargesSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, rupeesToPaisa, todayPk, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  AMOUNT_INVALID: 'The room fee must be above zero and the other amounts cannot be negative.',
  DEPOSIT_NOT_RECEIVED: 'The deposit has not been marked received yet.',
  DEPOSIT_REFUNDED: 'This deposit was already refunded.',
  STUDENT_STILL_HOUSED: 'The student still holds a bed on the refund date.',
  VOUCHER_REQUIRED: 'Enter the refund voucher number.',
  DEPOSIT_NOT_FOUND: 'Deposit not found.',
};

export async function saveTariff(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelTariffSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('save_hostel_tariff', {
    p_campus_id: p.data.campusId, p_room_type: p.data.roomType, p_monthly_paisa: rupeesToPaisa(p.data.monthly),
    p_mess_rate_paisa: rupeesToPaisa(p.data.messRate), p_deposit_paisa: rupeesToPaisa(p.data.deposit), p_effective_from: p.data.effectiveFrom,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/fees');
  return { error: null, message: 'Tariff saved.' };
}

export async function postCharges(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(postHostelChargesSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('post_hostel_charges', { p_month: p.data.month });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/fees');
  return { error: null, message: `${data ?? 0} ledger line(s) posted or corrected.` };
}

export async function receiveDeposit(depositId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(depositId).success) return { error: 'Invalid deposit.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('receive_hostel_deposit', { p_deposit_id: depositId, p_received_on: todayPk() });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/fees');
  return { error: null, message: 'Deposit marked received.' };
}

export async function refundDeposit(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(hostelDepositRefundSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('refund_hostel_deposit', { p_deposit_id: p.data.depositId, p_voucher_no: p.data.voucherNo });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/fees');
  return { error: null, message: 'Deposit refunded.' };
}
