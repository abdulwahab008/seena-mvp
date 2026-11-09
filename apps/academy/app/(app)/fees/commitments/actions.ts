'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'You do not have permission to do this.';
  if (m.includes('DATE_IN_PAST')) return 'The promised date cannot be in the past.';
  if (m.includes('MORE_THAN_OWED')) return 'That is more than the student owes.';
  if (m.includes('ENROLMENT_NOT_FOUND')) return 'That student has no enrolment here.';
  if (m.includes('COMMITMENT_NOT_FOUND')) return 'That promise no longer exists.';
  return 'Something went wrong. Try again.';
}

function refresh() {
  revalidatePath('/fees/commitments');
  revalidatePath('/fees/defaulters');
  revalidatePath('/dashboard');
}

const commitmentSchema = z.object({
  enrolmentId: z.string().uuid(),
  promisedDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  amountRupees: z.coerce.number().positive('Enter the amount').max(10_000_000),
  note: z.string().trim().max(300),
});

export async function addFeeCommitment(input: unknown): Promise<{ error: string | null }> {
  const p = commitmentSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_fee_commitment', {
    p_enrolment_id: p.data.enrolmentId,
    p_promised_date: p.data.promisedDate,
    p_amount_paisa: Math.round(p.data.amountRupees * 100),
    p_note: p.data.note || undefined,
  });
  if (error) return { error: message(error.message) };
  refresh();
  return { error: null };
}

const statusSchema = z.object({
  id: z.string().uuid(),
  status: z.enum(['kept', 'broken', 'cancelled']),
});

export async function setFeeCommitmentStatus(
  id: string,
  status: string,
): Promise<{ error: string | null }> {
  const p = statusSchema.safeParse({ id, status });
  if (!p.success) return { error: 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_fee_commitment_status', {
    p_id: p.data.id,
    p_status: p.data.status,
  });
  if (error) return { error: message(error.message) };
  refresh();
  return { error: null };
}

const writeOffSchema = z.object({
  enrolmentId: z.string().uuid(),
  amountRupees: z.coerce.number().positive('Enter the amount').max(10_000_000),
  reason: z.string().trim().min(3, 'Give a reason').max(300),
});

export async function writeOffBadDebt(input: unknown): Promise<{ error: string | null }> {
  const p = writeOffSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('write_off_bad_debt', {
    p_enrolment_id: p.data.enrolmentId,
    p_amount_paisa: Math.round(p.data.amountRupees * 100),
    p_reason: p.data.reason,
  });
  if (error) return { error: message(error.message) };
  refresh();
  return { error: null };
}
