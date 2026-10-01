'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { libraryErrorMessage } from '@/lib/library';

type Result = { error: string | null; amountPaisa?: number };

const uuid = z.string().uuid();

export async function settleFines(borrowerId: string, receiptId?: string): Promise<Result> {
  if (!uuid.safeParse(borrowerId).success) return { error: 'Invalid borrower.' };
  if (receiptId && !uuid.safeParse(receiptId.trim()).success) return { error: 'The receipt id must be a valid receipt reference.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('settle_library_fines', { p_borrower_id: borrowerId, p_receipt_id: receiptId?.trim() || undefined });
  if (error) return { error: libraryErrorMessage(error.message) };
  revalidatePath('/library/fines');
  return { error: null, amountPaisa: Number(data) };
}

export async function waiveFines(borrowerId: string, reason: string): Promise<Result> {
  if (!uuid.safeParse(borrowerId).success) return { error: 'Invalid borrower.' };
  if (reason.trim().length < 5) return { error: 'Give a reason of at least 5 characters.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('waive_library_fines', { p_borrower_id: borrowerId, p_reason: reason.trim() });
  if (error) {
    if (error.message.includes('REASON_REQUIRED')) return { error: 'Give a reason of at least 5 characters.' };
    return { error: libraryErrorMessage(error.message) };
  }
  revalidatePath('/library/fines');
  return { error: null, amountPaisa: Number(data) };
}
