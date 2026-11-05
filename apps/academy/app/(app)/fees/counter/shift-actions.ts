'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import {
  closeCounterSessionSchema,
  countersignCounterSessionSchema,
  createCashCounterSchema,
  openCounterSessionSchema,
  type CloseCounterSessionInput,
  type CountersignCounterSessionInput,
  type CreateCashCounterInput,
  type OpenCounterSessionInput,
} from '@/lib/validation';

type Result = { error: string | null };
export type CloseResult = Result & { varianceBlocked?: boolean };

const MESSAGES: [string, string][] = [
  ['COUNTER_NAME_TAKEN', 'A counter with that name already exists at this campus.'],
  ['COUNTER_NOT_FOUND', 'That counter is not available.'],
  ['COUNTER_SESSION_ALREADY_OPEN', 'This counter, or you at this campus, already has an open session.'],
  ['SESSION_NOT_FOUND', 'Session not found.'],
  ['SESSION_NOT_OPEN', 'This session is already closed.'],
  ['CANNOT_COUNTERSIGN_OWN_SESSION', 'You cannot countersign a session you opened.'],
  ['REMARK_TOO_SHORT', 'Give a remark of at least 10 characters.'],
  ['DENOMINATIONS_INVALID', 'The count has an invalid entry.'],
  ['FORBIDDEN', 'You do not have permission for this step.'],
];
const mapError = (message: string) => MESSAGES.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
const toPaisa = (pkr: number) => Math.round(pkr * 100);
const first = (e: z.ZodError | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

function settle(error: { message: string } | null): Result {
  if (error) return { error: mapError(error.message) };
  revalidatePath('/fees/counter');
  return { error: null };
}

export async function createCashCounter(input: CreateCashCounterInput): Promise<Result> {
  const p = createCashCounterSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_cash_counter', { p_campus_id: p.data.campusId, p_name: p.data.name, p_variance_threshold_paisa: toPaisa(p.data.thresholdPkr) });
  return settle(error);
}

export async function openCounterSession(input: OpenCounterSessionInput): Promise<Result> {
  const p = openCounterSessionSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('open_counter_session', { p_counter_id: p.data.counterId, p_opening_float_paisa: toPaisa(p.data.openingFloatPkr) });
  return settle(error);
}

export async function countersignCounterSession(input: CountersignCounterSessionInput): Promise<Result> {
  const p = countersignCounterSessionSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('countersign_counter_session', { p_session_id: p.data.sessionId, p_remark: p.data.remark });
  return settle(error);
}

export async function closeCounterSession(input: CloseCounterSessionInput): Promise<CloseResult> {
  const p = closeCounterSessionSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };

  const denominations = Object.fromEntries(Object.entries(p.data.counts).filter(([, count]) => count > 0));
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('close_counter_session', { p_session_id: p.data.sessionId, p_denominations: denominations });
  if (error) {
    if (error.message.includes('COUNTERSIGN_REQUIRED')) {
      return { error: 'The count is out by more than the allowed variance. A principal must countersign with a remark before this shift can close.', varianceBlocked: true };
    }
    return { error: mapError(error.message) };
  }
  revalidatePath('/fees/counter');
  return { error: null };
}
