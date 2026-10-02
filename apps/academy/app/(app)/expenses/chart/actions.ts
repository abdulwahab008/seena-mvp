'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const PATH = '/expenses/chart';

// ─── Types ───────────────────────────────────────────────────────────────────

export type ExpenseHeadRow = {
  id: string;
  tenant_id: string;
  code: string;
  name_en: string;
  name_ur: string;
  parent_id: string | null;
  level: number;
  is_leaf: boolean;
  requires_approval: boolean;
  is_active: boolean;
  budget_paisa: number | null;
  actual_paisa: number | null;
  remaining_paisa: number | null;
  is_overspent: boolean | null;
};

export type ActionState = { error: string | null; success?: boolean };

// ─── Helpers ─────────────────────────────────────────────────────────────────

function dbError(e: unknown): string {
  if (e && typeof e === 'object') {
    const err = e as Record<string, unknown>;
    const msg =
      (err.message as string) ||
      (err.error_description as string) ||
      'Unknown error';
    // Map DB error codes to friendly messages
    if (msg.includes('EXPENSE_HEAD_CYCLE_DETECTED')) return 'That parent would create a cycle.';
    if (msg.includes('EXPENSE_HEAD_MAX_DEPTH_EXCEEDED')) return 'Maximum hierarchy depth (5) reached.';
    if (msg.includes('EXPENSE_HEAD_NOT_LEAF')) return 'Vouchers can only be charged to leaf-level heads.';
    if (msg.includes('expense_head_tenant_code_uq')) return 'A head with that code already exists.';
    return msg;
  }
  return String(e);
}

// ─── Server Actions ───────────────────────────────────────────────────────────

/**
 * Load the full hierarchical chart for a campus/session/month combination.
 * Returns flat rows — the client builds the tree.
 */
export async function getExpenseChartData(
  campusId: string | null,
  sessionId: string | null,
  month: string | null,
): Promise<ExpenseHeadRow[]> {
  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { data, error } = await (supabase as any).rpc('get_expense_chart', {
    p_campus_id: campusId || null,
    p_session_id: sessionId || null,
    p_month: month || null,
  });
  if (error) throw new Error(dbError(error));
  return (data ?? []) as ExpenseHeadRow[];
}

/**
 * Create a new expense head (root or child).
 */
export async function createExpenseHead(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const code = (formData.get('code') as string | null)?.trim() ?? '';
  const nameEn = (formData.get('name_en') as string | null)?.trim() ?? '';
  const nameUr = (formData.get('name_ur') as string | null)?.trim() ?? '';
  const requiresApproval = formData.get('requires_approval') === 'true';

  if (!code) return { error: 'Code is required.' };
  if (!nameEn) return { error: 'English name is required.' };
  if (!nameUr) return { error: 'Urdu name is required.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_expense_head', {
    p_code: code,
    p_name_en: nameEn,
    p_name_ur: nameUr,
    p_requires_approval: requiresApproval,
  });

  if (error) return { error: dbError(error) };

  revalidatePath(PATH);
  return { error: null, success: true };
}

/**
 * Update an existing expense head (name, requires_approval, is_active, parent).
 */
export async function updateExpenseHead(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const id = formData.get('id') as string | null;
  if (!id) return { error: 'Head ID is required.' };

  const nameEn = (formData.get('name_en') as string | null)?.trim() || null;
  const nameUr = (formData.get('name_ur') as string | null)?.trim() || null;
  const requiresApprovalRaw = formData.get('requires_approval');
  const isActiveRaw = formData.get('is_active');
  const setParent = formData.get('set_parent') === 'true';
  const parentId = formData.get('parent_id') as string | null;

  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { error } = await (supabase as any).rpc('update_expense_head', {
    p_id: id,
    p_name_en: nameEn,
    p_name_ur: nameUr,
    p_requires_approval: requiresApprovalRaw !== null ? requiresApprovalRaw === 'true' : null,
    p_is_active: isActiveRaw !== null ? isActiveRaw === 'true' : null,
    p_set_parent: setParent,
    p_parent_id: setParent ? (parentId || null) : null,
  });

  if (error) return { error: dbError(error) };

  revalidatePath(PATH);
  return { error: null, success: true };
}

/**
 * Set (upsert) a monthly budget for a head.
 */
export async function saveExpenseBudget(
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const headId = formData.get('head_id') as string | null;
  const campusId = formData.get('campus_id') as string | null;
  const sessionId = formData.get('session_id') as string | null;
  const budgetMonth = formData.get('budget_month') as string | null;
  const amountRupees = parseFloat((formData.get('amount_rupees') as string | null) ?? '0');

  if (!headId) return { error: 'Head is required.' };
  if (!campusId) return { error: 'Campus is required.' };
  if (!sessionId) return { error: 'Session is required.' };
  if (!budgetMonth) return { error: 'Month is required.' };
  if (isNaN(amountRupees) || amountRupees < 0)
    return { error: 'Amount must be zero or positive.' };

  const amountPaisa = Math.round(amountRupees * 100);

  const supabase = await supabaseServer();
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const { error } = await (supabase as any).rpc('set_expense_budget', {
    p_head_id: headId,
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_budget_month: budgetMonth,
    p_amount_paisa: amountPaisa,
  });

  if (error) return { error: dbError(error) };

  revalidatePath(PATH);
  return { error: null, success: true };
}
