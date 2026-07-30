'use server';

import { revalidatePath } from 'next/cache';
import { lookupChallanSchema, collectCashPaymentSchema, printReceiptSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type LookupResult = {
  error: string | null;
  challanId?: string;
  studentName?: string;
  grNumber?: string;
  netPaisa?: number;
  outstandingPaisa?: number;
  status?: string;
};

type LookupResponse = {
  challan_id: string;
  student_name: string;
  gr_number: string;
  net_paisa: number;
  outstanding_paisa: number;
  status: string;
};

// FR-K17: scanning (or typing) a challan barcode resolves the student and
// pre-fills the amount with the challan's own outstanding balance.
export async function lookupChallan(_prev: LookupResult, formData: FormData): Promise<LookupResult> {
  const parsed = lookupChallanSchema.safeParse({ challanNo: formData.get('challanNo') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('lookup_challan_for_counter', { p_challan_no: parsed.data.challanNo });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to use the cash counter.' };
    if (error.message.includes('CHALLAN_NOT_FOUND')) return { error: 'No challan found for that number.' };
    return { error: 'Could not look up that challan.' };
  }

  const result = data as LookupResponse;
  return {
    error: null,
    challanId: result.challan_id,
    studentName: result.student_name,
    grNumber: result.gr_number,
    netPaisa: result.net_paisa,
    outstandingPaisa: result.outstanding_paisa,
    status: result.status,
  };
}

export type CollectResult = { error: string | null; receiptId?: string; isReplay?: boolean };

type CollectResponse = { receipt_id: string; receipt_no: string; payment_id: string; is_replay: boolean };

export async function collectCashPayment(_prev: CollectResult, formData: FormData): Promise<CollectResult> {
  const parsed = collectCashPaymentSchema.safeParse({
    challanId: formData.get('challanId'),
    amountRupees: formData.get('amountRupees'),
    mode: formData.get('mode'),
    clientIdempotencyKey: formData.get('clientIdempotencyKey'),
    referenceNo: formData.get('referenceNo') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('collect_cash_payment', {
    p_challan_id: parsed.data.challanId,
    p_amount_paisa: Math.round(parsed.data.amountRupees * 100),
    p_client_idempotency_key: parsed.data.clientIdempotencyKey,
    p_mode: parsed.data.mode,
    p_reference_no: parsed.data.referenceNo,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to collect payments.' };
    if (error.message.includes('CHALLAN_NOT_FOUND')) return { error: 'Challan not found.' };
    return { error: 'Could not collect the payment.' };
  }

  revalidatePath('/fees/challans');
  const result = data as CollectResponse;
  return { error: null, receiptId: result.receipt_id, isReplay: result.is_replay };
}

export type PrintResult = {
  error: string | null;
  receiptNo?: string;
  studentName?: string;
  grNumber?: string;
  amountWords?: string;
  amountPaisa?: number;
  postPaymentOutstandingPaisa?: number;
  printedCount?: number;
  isDuplicate?: boolean;
};

type PrintResponse = {
  receipt_no: string;
  student_name: string;
  gr_number: string;
  amount_words: string;
  amount_paisa: number;
  post_payment_outstanding_paisa: number;
  printed_count: number;
  is_duplicate: boolean;
};

// FR-K17: every call — first print or reprint — logs who and when;
// the second+ call is watermarked as a duplicate.
export async function printReceipt(_prev: PrintResult, formData: FormData): Promise<PrintResult> {
  const parsed = printReceiptSchema.safeParse({ receiptId: formData.get('receiptId') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('print_receipt', { p_receipt_id: parsed.data.receiptId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to print receipts.' };
    if (error.message.includes('RECEIPT_NOT_FOUND')) return { error: 'Receipt not found.' };
    return { error: 'Could not print the receipt.' };
  }

  const result = data as PrintResponse;
  return {
    error: null,
    receiptNo: result.receipt_no,
    studentName: result.student_name,
    grNumber: result.gr_number,
    amountWords: result.amount_words,
    amountPaisa: result.amount_paisa,
    postPaymentOutstandingPaisa: result.post_payment_outstanding_paisa,
    printedCount: result.printed_count,
    isDuplicate: result.is_duplicate,
  };
}
