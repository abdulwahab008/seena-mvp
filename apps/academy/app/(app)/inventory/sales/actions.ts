'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, type ActionError } from '@/lib/rpc-action';
import { saleReturnSchema, saleSchema, type SaleInput } from '@/lib/validation';

const MESSAGES: [string, string][] = [
  ['ALREADY_COVERED_BY_PACKAGE', 'The admission package already covers this item. Issue it from the package instead of selling it again.'],
  ['PACKAGE_ENTITLEMENT_EXCEEDED', 'That is more than the admission package still covers.'],
  ['INSUFFICIENT_STOCK', 'Not enough stock on hand to fill this sale.'],
  ['NO_ACTIVE_ENROLMENT', 'This student has no active enrolment to charge. Take cash instead.'],
  ['STORE_NOT_FOUND', 'This campus has no store yet. Create one under Stores and stock.'],
  ['RETURN_WINDOW_EXPIRED', 'The return window for this receipt has passed.'],
  ['RETURN_EXCEEDS_SOLD', 'That is more than was sold on this receipt.'],
  ['ITEM_NOT_ON_SALE', 'That item is not on this receipt.'],
  ['STUDENT_NOT_FOUND', 'Student not found.'],
  ['FORBIDDEN', 'You do not have permission for this sale.'],
];
const first = (e: { issues: { message: string }[] } | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

export async function createSaleAction(input: SaleInput): Promise<ActionError & { saleId?: string }> {
  const p = saleSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_sale', {
    p_student_id: p.data.studentId,
    p_settlement: p.data.settlement,
    p_lines: p.data.lines.map((l) => ({ item_id: l.itemId, qty: l.qty, from_package: l.fromPackage })),
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/inventory/sales');
  return { error: null, saleId: (data as { sale_id: string }).sale_id };
}

export async function returnItemAction(input: Record<string, string>): Promise<ActionError> {
  const p = saleReturnSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('return_sale_items', { p_sale_id: p.data.saleId, p_lines: [{ item_id: p.data.itemId, qty: p.data.qty }] });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/inventory/sales');
  return { error: null };
}
