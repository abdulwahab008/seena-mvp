'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { resolveBankExceptionSchema, type ResolveBankExceptionInput } from '@/lib/validation';

const idSchema = z.string().uuid();

function mapError(message: string): string {
  if (message.includes('UNRESOLVED_EXCEPTIONS')) return 'Resolve every exception before closing this import.';
  if (message.includes('CANCELLED_CHALLAN_CANNOT_BE_POSTED')) return 'A cancelled challan cannot be paid. Dismiss this line with a note.';
  if (message.includes('CHALLAN_REQUIRED')) return 'Enter the challan number this payment belongs to.';
  if (message.includes('PAYMENT_ALREADY_POSTED')) return 'A payment with this bank reference is already posted.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission for this.';
  return 'Something went wrong. Please try again.';
}

export async function reconcileImport(importId: string): Promise<{ error: string | null; matched?: number; exceptions?: number }> {
  if (!idSchema.safeParse(importId).success) return { error: 'Invalid import.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('reconcile_bank_import', { p_import_id: importId });
  if (error) return { error: mapError(error.message) };
  const r = z.object({ matched: z.number(), exceptions: z.number() }).parse(data);
  revalidatePath(`/fees/bank-statements/${importId}`);
  return { error: null, matched: r.matched, exceptions: r.exceptions };
}

export async function resolveException(importId: string, input: ResolveBankExceptionInput): Promise<{ error: string | null }> {
  const parsed = resolveBankExceptionSchema.safeParse(input);
  if (!parsed.success || !idSchema.safeParse(importId).success) return { error: parsed.success ? 'Invalid import.' : (parsed.error.issues[0]?.message ?? 'Invalid input.') };

  const supabase = await supabaseServer();
  let challanId: string | null = null;
  if (parsed.data.challanNo) {
    const { data } = await supabase.from('fee_challan').select('id').eq('challan_digits', parsed.data.challanNo).limit(2);
    if (!data || data.length !== 1) return { error: 'No single challan matches that number.' };
    challanId = data[0]!.id;
  }
  const { error } = await supabase.rpc('resolve_bank_exception', {
    p_exception_id: parsed.data.exceptionId,
    p_action: parsed.data.action,
    p_note: parsed.data.note,
    p_challan_id: challanId ?? undefined,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/fees/bank-statements/${importId}`);
  return { error: null };
}

export async function closeImport(importId: string): Promise<{ error: string | null }> {
  if (!idSchema.safeParse(importId).success) return { error: 'Invalid import.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('close_bank_import', { p_import_id: importId });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/fees/bank-statements/${importId}`);
  return { error: null };
}
