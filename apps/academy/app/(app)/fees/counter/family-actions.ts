'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { FEE_PAYMENT_MODES } from '@/lib/validation';
import type { Database } from '@/lib/database.types';

export type FamilyChild = Database['public']['Functions']['family_fee_lookup']['Returns'][number];

export async function lookupFamily(query: string): Promise<{ error: string | null; children: FamilyChild[] }> {
  const q = z.string().trim().min(1, 'Enter a family number, CNIC, mobile or GR number').max(40).safeParse(query);
  if (!q.success) return { error: q.error.issues[0]?.message ?? 'Invalid search.', children: [] };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('family_fee_lookup', { p_query: q.data });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You cannot look up family dues.' : 'Search failed.', children: [] };
  if (!data.length) return { error: 'No family matches that search.', children: [] };
  return { error: null, children: data };
}

const familyPaymentSchema = z.object({
  familyGroupId: z.string().uuid(),
  amountRupees: z.coerce.number().positive('Enter an amount'),
  mode: z.enum(FEE_PAYMENT_MODES),
  referenceNo: z.string().trim().max(100).optional(),
  clientIdempotencyKey: z.string().min(1),
});

type Receipt = { receipt_no: string; student_name: string; amount_paisa: number; is_replay: boolean };

export async function collectFamilyPayment(input: z.input<typeof familyPaymentSchema>): Promise<{ error: string | null; receipts: Receipt[] }> {
  const p = familyPaymentSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.', receipts: [] };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('collect_family_payment', {
    p_family_group_id: p.data.familyGroupId,
    p_amount_paisa: Math.round(p.data.amountRupees * 100),
    p_client_idempotency_key: p.data.clientIdempotencyKey,
    p_mode: p.data.mode,
    p_reference_no: p.data.referenceNo || undefined,
  });
  if (error) {
    const m = error.message;
    if (m.includes('FORBIDDEN')) return { error: 'You do not have permission to collect payments.', receipts: [] };
    if (m.includes('AMOUNT_EXCEEDS_DUES')) return { error: 'That is more than the family owes.', receipts: [] };
    if (m.includes('NOTHING_DUE')) return { error: 'This family has nothing due.', receipts: [] };
    if (m.includes('COUNTER_SESSION_REQUIRED')) return { error: 'Open a counter shift first.', receipts: [] };
    return { error: 'Could not collect the payment.', receipts: [] };
  }
  revalidatePath('/fees/challans');
  return { error: null, receipts: ((data as { receipts: Receipt[] }).receipts) ?? [] };
}
