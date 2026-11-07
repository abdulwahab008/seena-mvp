'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only the accountant and owner can post to the ledger.';
  if (m.includes('NOT_BALANCED')) return 'Debits and credits must be equal.';
  if (m.includes('LINES_REQUIRED')) return 'A voucher needs at least two lines.';
  if (m.includes('DATE_INVALID')) return 'A voucher cannot be dated in the future.';
  if (m.includes('ACCOUNT_TYPE_LOCKED')) return 'This account has postings, so its type cannot change.';
  if (m.includes('CANNOT_REVERSE')) return 'This voucher is already a reversal or has been reversed.';
  if (m.includes('uq_gl_account_code')) return 'That account code is already used.';
  if (m.includes('gl_account_code_check')) return 'Account codes are 3 to 8 digits.';
  return 'Something went wrong. Try again.';
}

export async function ensureChart(): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('ensure_chart_of_accounts');
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}

const accountSchema = z.object({
  code: z.string().trim().regex(/^\d{3,8}$/, 'Account codes are 3 to 8 digits'),
  name: z.string().trim().min(1, 'Enter a name').max(150),
  type: z.enum(['asset', 'liability', 'equity', 'income', 'expense']),
});

export async function addAccount(input: unknown): Promise<{ error: string | null }> {
  const p = accountSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_gl_account', { p_code: p.data.code, p_name: p.data.name, p_type: p.data.type });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}

const voucherSchema = z.object({
  entryDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  narration: z.string().trim().min(1, 'Enter a narration').max(500),
  lines: z
    .array(
      z.object({
        accountId: z.string().uuid('Choose an account'),
        debit: z.coerce.number().min(0),
        credit: z.coerce.number().min(0),
        memo: z.string().trim().max(200).optional(),
      }),
    )
    .min(2, 'A voucher needs at least two lines'),
});

export async function postVoucher(input: unknown): Promise<{ error: string | null }> {
  const p = voucherSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the voucher.' };
  const lines = p.data.lines
    .filter((l) => l.debit > 0 || l.credit > 0)
    .map((l) => ({ account_id: l.accountId, debit: Math.round(l.debit * 100), credit: Math.round(l.credit * 100), memo: l.memo ?? null }));
  if (lines.some((l) => l.debit > 0 && l.credit > 0)) return { error: 'A line is either a debit or a credit, not both.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_journal_entry', { p_entry_date: p.data.entryDate, p_narration: p.data.narration, p_lines: lines });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}

export async function reverseVoucher(entryId: string, reason: string): Promise<{ error: string | null }> {
  const p = z.object({ entryId: z.string().uuid(), reason: z.string().trim().min(1, 'Give a reason').max(300) }).safeParse({ entryId, reason });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Give a reason.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reverse_journal_entry', { p_entry_id: p.data.entryId, p_reason: p.data.reason });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}
