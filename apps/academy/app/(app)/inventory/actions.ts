'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, toPaisa, type ActionError } from '@/lib/rpc-action';
import { invItemSchema, invStoreSchema, stockReceiptSchema, stockTakeSchema } from '@/lib/validation';

const MESSAGES: [string, string][] = [
  ['INSUFFICIENT_STOCK', 'Not enough stock on hand for this movement.'],
  ['ITEM_CODE_EXISTS', 'An item with this code already exists.'],
  ['STORE_EXISTS', 'This campus already has a store with that name.'],
  ['STORE_NOT_FOUND', 'That store was not found.'],
  ['ITEM_NOT_FOUND', 'That item was not found.'],
  ['REASON_CODE_INVALID', 'Choose a reason for the stock-take variance.'],
  ['FORBIDDEN', 'You do not have permission for this store.'],
];
const first = (e: { issues: { message: string }[] } | undefined) => e?.issues[0]?.message ?? 'Invalid input.';

export async function createItem(input: Record<string, string>): Promise<ActionError> {
  const p = invItemSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_inv_item', {
    p_item_code: p.data.itemCode,
    p_name: p.data.name,
    p_category: p.data.category,
    p_uom: p.data.uom || undefined,
    p_size: p.data.size || undefined,
    p_class_id: p.data.classId || undefined,
    p_subject_id: p.data.subjectId || undefined,
    p_reorder_level: p.data.reorderLevel,
    p_sale_price: toPaisa(p.data.salePricePkr),
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/inventory');
  return { error: null };
}

export async function createStore(input: Record<string, string>): Promise<ActionError> {
  const p = invStoreSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_inv_store', { p_campus_id: p.data.campusId, p_name: p.data.name });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/inventory');
  return { error: null };
}

export async function receiveStock(input: Record<string, string>): Promise<ActionError> {
  const p = stockReceiptSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_stock_movement', {
    p_store_id: p.data.storeId,
    p_item_id: p.data.itemId,
    p_type: 'receipt',
    p_qty: p.data.qty,
    p_unit_cost: p.data.unitCostPkr === undefined ? undefined : toPaisa(p.data.unitCostPkr),
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/inventory');
  return { error: null };
}

export async function postStockTake(input: Record<string, string>): Promise<ActionError> {
  const p = stockTakeSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_stock_variance', {
    p_store_id: p.data.storeId,
    p_item_id: p.data.itemId,
    p_counted: p.data.counted,
    p_reason_code: p.data.reasonCode,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/inventory');
  return { error: null };
}
