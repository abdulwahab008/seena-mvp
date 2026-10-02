'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { clientIpFromHeaders } from '@/lib/request-ip';
import {
  IMPERSONATION_WRITE_BLOCKED_MESSAGE,
  isImpersonationWriteBlocked,
  recordBlockedWrite,
} from '@/lib/impersonation';
import { expenseError } from '@/lib/expenses/errors';
import {
  ALLOWED_DOCUMENT_MIME_TYPES,
  MAX_DOCUMENT_FILE_SIZE,
  markExpenseVoucherPaidSchema,
  rupeesToPaisa,
  submitExpenseVoucherSchema,
} from '@/lib/validation';

/**
 * FR-L11. Nothing here writes to expense_voucher directly:
 * submit_expense_voucher() and mark_expense_voucher_paid() own the only
 * transitions the status guard accepts, so an action that tried to be
 * clever with a direct update would simply be refused.
 */

const PATH = '/expenses/vouchers';

export type SubmitVoucherState = {
  error: string | null;
  voucherId?: string;
  status?: string;
  requiredApproverRole?: string | null;
  possibleThresholdSplit?: boolean;
};

export type PayVoucherState = { error: string | null; voucherId?: string };


// AC4: the address the request came from. See lib/request-ip.ts for what it
// is worth and where it is not evidence.
async function requestIp(): Promise<string | null> {
  return clientIpFromHeaders(await headers());
}

export async function submitExpenseVoucher(
  _prev: SubmitVoucherState,
  formData: FormData,
): Promise<SubmitVoucherState> {
  const parsed = submitExpenseVoucherSchema.safeParse({
    campusId: formData.get('campusId'),
    headId: formData.get('headId'),
    payeeName: formData.get('payeeName'),
    payeeNtn: formData.get('payeeNtn') ?? '',
    amountRupees: formData.get('amountRupees'),
    voucherDate: formData.get('voucherDate'),
    narrative: formData.get('narrative') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  let attachmentPath: string | null = null;

  // The bill is uploaded BEFORE the voucher row exists: expense_voucher is
  // append-only in its content, so there is no row to repair if an upload
  // fails halfway. A failed submit leaves an object nobody can read (the
  // bucket's SELECT policy needs a voucher pointing at it), never a voucher
  // with a broken attachment.
  const file = formData.get('attachment');
  if (file instanceof File && file.size > 0) {
    if (file.size > MAX_DOCUMENT_FILE_SIZE) return { error: 'Maximum file size 5 MB.' };
    if (!ALLOWED_DOCUMENT_MIME_TYPES.includes(file.type as (typeof ALLOWED_DOCUMENT_MIME_TYPES)[number])) {
      return { error: 'Only JPEG, PNG and PDF bills are accepted.' };
    }
    const ext = file.name.includes('.') ? file.name.split('.').pop()!.toLowerCase() : 'bin';

    const { data: path, error: reserveError } = await supabase.rpc('reserve_expense_attachment_path', {
      p_campus_id: parsed.data.campusId,
      p_file_ext: ext,
      p_file_size: file.size,
      p_mime_type: file.type,
    });
    if (reserveError || !path) {
      return { error: reserveError ? expenseError(reserveError.message) : 'Could not prepare the bill upload.' };
    }

    const { error: uploadError } = await supabase.storage
      .from('expense-attachments')
      .upload(path, file, { contentType: file.type, upsert: false });
    if (uploadError) return { error: 'Upload failed. Please try again.' };
    attachmentPath = path;
  }

  const { data, error } = await supabase.rpc('submit_expense_voucher', {
    p_campus_id: parsed.data.campusId,
    p_head_id: parsed.data.headId,
    p_payee_name: parsed.data.payeeName,
    p_amount_paisa: rupeesToPaisa(parsed.data.amountRupees),
    p_voucher_date: parsed.data.voucherDate,
    p_payee_ntn: parsed.data.payeeNtn || undefined,
    p_narrative: parsed.data.narrative || undefined,
    p_attachment_path: attachmentPath ?? undefined,
    p_request_ip: (await requestIp()) ?? undefined,
  });
  // FR-A16 AC3. app.tg_block_impersonated_write() raised and took the whole
  // transaction with it, so the durable record has to be written by a second
  // one — this error path is the only place that knows the attempt happened.
  if (error && isImpersonationWriteBlocked(error.message)) {
    await recordBlockedWrite(supabase, 'expense_voucher', 'submit_expense_voucher');
    return { error: IMPERSONATION_WRITE_BLOCKED_MESSAGE };
  }
  if (error || !data) return { error: error ? expenseError(error.message) : 'Could not submit the voucher.' };

  const result = data as unknown as {
    voucher_id: string;
    status: string;
    required_approver_role: string | null;
    possible_threshold_split: boolean;
  };

  revalidatePath(PATH);
  revalidatePath('/expenses/approvals');
  return {
    error: null,
    voucherId: result.voucher_id,
    status: result.status,
    requiredApproverRole: result.required_approver_role,
    possibleThresholdSplit: result.possible_threshold_split,
  };
}

export async function markExpenseVoucherPaid(formData: FormData): Promise<PayVoucherState> {
  const parsed = markExpenseVoucherPaidSchema.safeParse({
    voucherId: formData.get('voucherId'),
    paidReference: formData.get('paidReference') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('mark_expense_voucher_paid', {
    p_voucher_id: parsed.data.voucherId,
    p_paid_reference: parsed.data.paidReference || undefined,
  });
  if (error || !data) return { error: error ? expenseError(error.message) : 'Could not record the payment.' };

  revalidatePath(PATH);
  revalidatePath('/expenses/approvals');
  return { error: null, voucherId: parsed.data.voucherId };
}

export async function getExpenseAttachmentUrl(path: string): Promise<{ url: string | null; error: string | null }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.storage.from('expense-attachments').createSignedUrl(path, 60);
  if (error || !data) return { url: null, error: 'Could not open the bill.' };
  return { url: data.signedUrl, error: null };
}
