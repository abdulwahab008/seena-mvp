'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only the accountant and owner can post to the ledger.';
  if (m.includes('NOT_BALANCED')) return 'Debits and credits must be equal.';
  if (m.includes('LINES_REQUIRED')) return 'A voucher needs at least two lines.';
  if (m.includes('DATE_INVALID')) return 'Choose a date that has already passed.';
  if (m.includes('ACCOUNT_TYPE_LOCKED')) return 'This account has postings, so its type cannot change.';
  if (m.includes('CANNOT_REVERSE')) return 'This voucher is already a reversal or has been reversed.';
  if (m.includes('ACCOUNT_NOT_FOUND')) return 'Fee heads post to an income account and expense heads to an expense account.';
  if (m.includes('PERIOD_LOCKED')) return 'That date is in a closed year.';
  if (m.includes('OPENING_ALREADY_POSTED')) return 'Opening balances are already posted. Correct them with a journal voucher.';
  if (m.includes('uq_gl_account_code')) return 'That account code is already used.';
  if (m.includes('gl_account_code_check')) return 'Account codes are 3 to 8 digits.';
  if (m.includes('COST_CENTER_NOT_FOUND')) return 'Choose an active cost centre.';
  if (m.includes('uq_gl_cost_center_code')) return 'That cost centre code is already used.';
  if (m.includes('gl_cost_center_code_check')) return 'Cost centre codes are up to 12 letters, digits or dashes.';
  if (m.includes('TEMPLATE_NOT_FOUND')) return 'That recurring voucher no longer exists.';
  if (m.includes('AMOUNTS_INVALID')) return 'Enter twelve monthly amounts, none negative.';
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
        costCenterId: z.union([z.string().uuid(), z.literal('')]).optional(),
      }),
    )
    .min(2, 'A voucher needs at least two lines'),
});

type VoucherLineInput = z.infer<typeof voucherSchema>['lines'][number];

function toPaisaLines(lines: VoucherLineInput[]) {
  return lines
    .filter((l) => l.debit > 0 || l.credit > 0)
    .map((l) => ({
      account_id: l.accountId,
      debit: Math.round(l.debit * 100),
      credit: Math.round(l.credit * 100),
      memo: l.memo ?? null,
      cost_center_id: l.costCenterId || null,
    }));
}

export async function postVoucher(input: unknown): Promise<{ error: string | null }> {
  const p = voucherSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the voucher.' };
  const lines = toPaisaLines(p.data.lines);
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

export async function backfillLedger(): Promise<{ error: string | null; posted: number }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('post_ledger_backfill');
  if (error) return { error: message(error.message), posted: 0 };
  revalidatePath('/accounts');
  return { error: null, posted: data ?? 0 };
}

const headSchema = z.object({ kind: z.enum(['fee', 'expense']), headId: z.string().uuid(), code: z.string().regex(/^(\d{3,8})?$/) });

export async function setHeadAccount(input: unknown): Promise<{ error: string | null }> {
  const p = headSchema.safeParse(input);
  if (!p.success) return { error: 'Choose an account.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_head_gl_code', { p_kind: p.data.kind, p_head_id: p.data.headId, p_code: p.data.code });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}

const openingSchema = z.object({
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  lines: z.array(z.object({ accountId: z.string().uuid(), amount: z.coerce.number().min(0, 'Amounts cannot be negative') })),
});

export async function postOpeningBalances(input: unknown): Promise<{ error: string | null }> {
  const p = openingSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the amounts.' };
  const lines = p.data.lines.filter((l) => l.amount > 0).map((l) => ({ account_id: l.accountId, amount: Math.round(l.amount * 100) }));
  if (lines.length === 0) return { error: 'Enter at least one balance.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_opening_balances', { p_date: p.data.date, p_lines: lines });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}

export async function closeYear(yearEnd: string): Promise<{ error: string | null }> {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(yearEnd)) return { error: 'Choose the last day of the year.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('close_financial_year', { p_year_end: yearEnd });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts');
  return { error: null };
}

const costCenterSchema = z.object({
  id: z.string().uuid().optional(),
  code: z.string().trim().toUpperCase().regex(/^[A-Z0-9-]{1,12}$/, 'Up to 12 letters, digits or dashes'),
  name: z.string().trim().min(1, 'Enter a name').max(150),
  isActive: z.boolean().default(true),
});

export async function saveCostCenter(input: unknown): Promise<{ error: string | null }> {
  const p = costCenterSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_gl_cost_center', { p_code: p.data.code, p_name: p.data.name, p_is_active: p.data.isActive, p_id: p.data.id });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts', 'layout');
  return { error: null };
}

const recurringSchema = voucherSchema.omit({ entryDate: true }).extend({
  id: z.string().uuid().optional(),
  name: z.string().trim().min(1, 'Enter a name').max(150),
  frequency: z.enum(['monthly', 'quarterly', 'yearly']),
  nextRun: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose the next due date'),
});

export async function saveRecurringJournal(input: unknown): Promise<{ error: string | null }> {
  const p = recurringSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the voucher.' };
  const lines = toPaisaLines(p.data.lines);
  if (lines.some((l) => l.debit > 0 && l.credit > 0)) return { error: 'A line is either a debit or a credit, not both.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_recurring_journal', {
    p_name: p.data.name,
    p_narration: p.data.narration,
    p_frequency: p.data.frequency,
    p_next_run: p.data.nextRun,
    p_lines: lines,
    p_id: p.data.id,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts/recurring');
  return { error: null };
}

export async function setRecurringJournalActive(id: string, isActive: boolean): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'That recurring voucher no longer exists.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_recurring_journal_active', { p_id: id, p_is_active: isActive });
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts/recurring');
  return { error: null };
}

export async function postDueRecurringJournals(): Promise<{ error: string | null; posted: number }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('post_due_recurring_journals');
  if (error?.message.includes('ACCOUNT_NOT_FOUND')) return { error: 'A due voucher uses an account that has since been closed. Edit or pause it.', posted: 0 };
  if (error) return { error: message(error.message), posted: 0 };
  revalidatePath('/accounts', 'layout');
  return { error: null, posted: data ?? 0 };
}

const budgetSchema = z.object({
  accountId: z.string().uuid('Choose an account'),
  fyStartYear: z.number().int().min(2000).max(2100),
  amounts: z.array(z.coerce.number().min(0, 'Amounts cannot be negative')).length(12),
});

export async function saveAccountBudget(input: unknown): Promise<{ error: string | null }> {
  const p = budgetSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the amounts.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_account_budget', {
    p_account_id: p.data.accountId,
    p_fy_start_year: p.data.fyStartYear,
    p_amounts: p.data.amounts.map((a) => Math.round(a * 100)),
  });
  if (error?.message.includes('ACCOUNT_NOT_FOUND')) return { error: 'Budgets are for income and expense accounts.' };
  if (error) return { error: message(error.message) };
  revalidatePath('/accounts/budgets');
  return { error: null };
}
