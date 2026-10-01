'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, toPaisa, type ActionError } from '@/lib/rpc-action';
import { goodsReceiptSchema, requisitionSchema, thresholdTiersSchema, type GoodsReceiptInput, type RequisitionInput, type ThresholdTiersInput } from '@/lib/validation';

const MESSAGES: [string, string][] = [
  ['OUT_OF_ORDER', 'An earlier approver must decide this first.'],
  ['THRESHOLDS_NOT_CONFIGURED', 'Approval thresholds have not been set. Ask the Owner to set them.'],
  ['REQUISITION_LOCKED', 'This requisition has been decided and can no longer be edited.'],
  ['REQUISITION_NOT_PENDING', 'This requisition is not waiting for approval.'],
  ['REQUISITION_NOT_DRAFT', 'This requisition has already been submitted.'],
  ['REQUISITION_NOT_APPROVED', 'Only an approved requisition can become a purchase order.'],
  ['RECEIPT_EXCEEDS_ORDER', 'That is more than was ordered. Short deliveries are fine; over-deliveries need a new order.'],
  ['PURCHASE_ORDER_CLOSED', 'This purchase order is already fulfilled.'],
  ['TIERS_INVALID', 'Each approval limit must be above the one before, and only the last tier can be open-ended.'],
  ['REMARKS_REQUIRED', 'Say why you are rejecting it.'],
  ['VENDOR_NOT_FOUND', 'Choose a vendor.'],
  ['STORE_NOT_FOUND', 'Choose a store at the purchasing campus.'],
  ['AMOUNT_MUST_BE_POSITIVE', 'The requisition needs a cost before it can be submitted.'],
  ['FORBIDDEN', 'You are not allowed to do this step.'],
];
const first = (e: { issues: { message: string }[] } | undefined) => e?.issues[0]?.message ?? 'Invalid input.';
const uuid = z.string().uuid();
const toLines = (lines: z.output<typeof requisitionSchema>['lines']) =>
  lines.map((l) => ({ item_id: l.itemId || null, description: l.description, qty: l.qty, est_unit_cost: toPaisa(l.estUnitCostPkr) }));

export async function createRequisitionAction(input: RequisitionInput): Promise<ActionError & { reqId?: string }> {
  const p = requisitionSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('create_requisition', {
    p_campus_id: p.data.campusId,
    p_justification: p.data.justification,
    p_lines: toLines(p.data.lines),
    p_department_id: p.data.departmentId || undefined,
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/purchasing');
  return { error: null, reqId: data as string };
}

export async function updateRequisitionAction(reqId: string, input: RequisitionInput): Promise<ActionError> {
  if (!uuid.safeParse(reqId).success) return { error: 'Invalid requisition.' };
  const p = requisitionSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('update_requisition', { p_req_id: reqId, p_justification: p.data.justification, p_lines: toLines(p.data.lines) });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath(`/purchasing/${reqId}`);
  revalidatePath('/purchasing');
  return { error: null };
}

export async function submitRequisitionAction(reqId: string): Promise<ActionError> {
  if (!uuid.safeParse(reqId).success) return { error: 'Invalid requisition.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('submit_requisition', { p_req_id: reqId });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath(`/purchasing/${reqId}`);
  revalidatePath('/purchasing');
  return { error: null };
}

export async function decideRequisitionAction(reqId: string, decision: 'approve' | 'reject', remarks: string): Promise<ActionError> {
  if (!uuid.safeParse(reqId).success) return { error: 'Invalid requisition.' };
  const supabase = await supabaseServer();
  const { error } =
    decision === 'approve'
      ? await supabase.rpc('approve_requisition', { p_req_id: reqId, p_remarks: remarks || undefined })
      : await supabase.rpc('reject_requisition', { p_req_id: reqId, p_remarks: remarks });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath(`/purchasing/${reqId}`);
  revalidatePath('/purchasing');
  return { error: null };
}

export async function convertToPoAction(input: Record<string, string>): Promise<ActionError> {
  const p = z.object({ reqId: uuid, vendorId: z.string().uuid('Choose a vendor') }).safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('convert_to_purchase_order', { p_req_id: p.data.reqId, p_vendor_id: p.data.vendorId });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/purchasing');
  revalidatePath('/purchasing/orders');
  return { error: null };
}

export async function saveThresholdsAction(input: ThresholdTiersInput): Promise<ActionError> {
  const p = thresholdTiersSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_purchase_thresholds', {
    p_tiers: p.data.tiers.map((t) => ({ upto_amount: typeof t.uptoPkr === 'number' ? toPaisa(t.uptoPkr) : null, approver_role: t.role })),
    p_campus_id: p.data.campusId || undefined,
    p_effective_from: new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' }),
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/purchasing');
  return { error: null };
}

export async function postGoodsReceiptAction(input: GoodsReceiptInput): Promise<ActionError> {
  const p = goodsReceiptSchema.safeParse(input);
  if (!p.success) return { error: first(p.error) };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_goods_receipt', {
    p_po_id: p.data.poId,
    p_store_id: p.data.storeId,
    p_lines: p.data.lines.map((l) => ({ po_line_id: l.poLineId, qty_received: l.qtyReceived })),
  });
  if (error) return { error: mapRpcError(error.message, MESSAGES) };
  revalidatePath('/purchasing/orders');
  revalidatePath('/inventory');
  return { error: null };
}
