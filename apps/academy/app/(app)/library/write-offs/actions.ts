'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { formatPkrCompact } from '@/lib/format-money';
import { libraryWriteOffSchema, type LibraryWriteOffInput } from '@/lib/validation';
import { libraryErrorMessage, pkrToPaisa } from '@/lib/library';

type Result = { error: string | null; message?: string };

function describe(message: string): string {
  if (message.includes('MARKET_VALUE_REQUIRED')) return 'Enter the market value for this basis.';
  if (message.includes('PURCHASE_COST_MISSING')) return 'This copy has no purchase cost on record: use the market basis and enter a value.';
  if (message.includes('BASIS_INVALID')) return 'Check the basis and multiplier.';
  return libraryErrorMessage(message);
}

export async function writeOff(input: LibraryWriteOffInput): Promise<Result> {
  const p = libraryWriteOffSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data: copy } = await supabase.from('library_copy').select('id').eq('barcode', p.data.barcode).maybeSingle();
  if (!copy) return { error: 'No copy has that barcode.' };

  const { data, error } = await supabase.rpc('write_off_copy', {
    p_copy_id: copy.id,
    p_basis: p.data.basis,
    p_multiplier: p.data.multiplier ? Number(p.data.multiplier) : undefined,
    p_market_value: pkrToPaisa(p.data.marketValuePkr),
    p_reason: p.data.reason || undefined,
  });
  if (error) return { error: describe(error.message) };
  const r = data as unknown as { ok: boolean; error?: string; charge_amount?: number; fee_ledger_id?: string | null };
  if (!r.ok) return { error: 'Only the librarian, principal or owner can write a copy off. This attempt has been recorded.' };
  revalidatePath('/library/write-offs');
  const charge = Number(r.charge_amount ?? 0);
  return {
    error: null,
    message: charge > 0 ? `Written off. ${formatPkrCompact(charge)} ${r.fee_ledger_id ? 'was posted to the student fee ledger as LIB_RECOVERY' : 'is to be recovered outside the student fee ledger'}.` : 'Written off at no charge.',
  };
}

export async function reverseWriteOff(writeOffId: string, reason: string): Promise<Result> {
  if (!z.string().uuid().safeParse(writeOffId).success) return { error: 'Invalid write-off.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reverse_write_off', { p_write_off_id: writeOffId, p_reason: reason.trim() || undefined });
  if (error) return { error: describe(error.message) };
  revalidatePath('/library/write-offs');
  return { error: null, message: 'Reversed: the charge was credited back and the copy is on the shelf again.' };
}
