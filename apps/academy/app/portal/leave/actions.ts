'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import type { MessageKey } from '@/lib/i18n/messages';
import { leaveApplicationSchema } from '@/lib/validation';

const MAX_FILES = 3;
const MAX_FILE_BYTES = 10 * 1024 * 1024;
const MIME = ['application/pdf', 'image/jpeg', 'image/png'];

export type LeaveResult = { error: { key: MessageKey; vars?: Record<string, string> } | null; fileErrors: { name: string; key: MessageKey }[] };
const fail = (key: MessageKey, vars?: Record<string, string>): LeaveResult => ({ error: { key, vars }, fileErrors: [] });

function mapSubmitError(message: string, detail: string | undefined): LeaveResult {
  if (message.includes('LEAVE_END_BEFORE_START')) return fail('leave.errEndBeforeStart');
  if (message.includes('LEAVE_OVERLAP')) return fail('leave.errOverlap', { date: /date=(\d{4}-\d{2}-\d{2})/.exec(detail ?? message)?.[1] ?? '' });
  if (message.includes('REMARKS_TOO_LONG')) return fail('leave.errRemarks');
  if (message.includes('FORBIDDEN') || message.includes('42501')) return fail('leave.errForbidden');
  return fail('leave.errGeneric');
}

function mapAttachError(message: string): MessageKey {
  if (message.includes('ATTACHMENTS_TOTAL_TOO_LARGE')) return 'leave.errTotalTooLarge';
  if (message.includes('TOO_MANY_ATTACHMENTS')) return 'leave.errTooMany';
  if (message.includes('ATTACHMENT_TYPE_NOT_ALLOWED')) return 'leave.errType';
  return 'leave.errGeneric';
}

export async function submitLeave(formData: FormData): Promise<LeaveResult> {
  const parsed = leaveApplicationSchema.safeParse({
    enrolmentId: formData.get('enrolmentId'),
    fromDate: formData.get('fromDate'),
    toDate: formData.get('toDate'),
    category: formData.get('category'),
    remarks: (formData.get('remarks') as string | null) || undefined,
  });
  if (!parsed.success) {
    const msg = parsed.error.issues[0]?.message ?? 'leave.errGeneric';
    return fail(msg.startsWith('leave.') ? (msg as MessageKey) : 'leave.errGeneric');
  }
  const files = formData.getAll('files').filter((f): f is File => f instanceof File && f.size > 0);
  if (files.length > MAX_FILES) return fail('leave.errTooMany');

  const supabase = await supabaseServer();
  const { data: leaveId, error } = await supabase.rpc('submit_student_leave', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_from_date: parsed.data.fromDate,
    p_to_date: parsed.data.toDate,
    p_reason_category: parsed.data.category,
    p_remarks: parsed.data.remarks,
  });
  if (error || !leaveId) return mapSubmitError(error?.message ?? '', error?.details ?? undefined);

  const fileErrors: LeaveResult['fileErrors'] = [];
  const service = supabaseServiceRole();
  for (const file of files) {
    if (!MIME.includes(file.type) || file.size > MAX_FILE_BYTES) {
      fileErrors.push({ name: file.name, key: MIME.includes(file.type) ? 'leave.errTotalTooLarge' : 'leave.errType' });
      continue;
    }
    const { data, error: attachError } = await supabase.rpc('add_leave_attachment', { p_leave_id: leaveId, p_file_name: file.name, p_mime_type: file.type, p_size_bytes: file.size });
    if (attachError) {
      fileErrors.push({ name: file.name, key: mapAttachError(attachError.message) });
      continue;
    }
    const meta = z.object({ attachment_id: z.string().uuid(), storage_path: z.string() }).parse(data);
    const { error: uploadError } = await service.storage.from('leave-attachments').upload(meta.storage_path, file, { contentType: file.type });
    if (uploadError) {
      await supabase.rpc('remove_leave_attachment', { p_attachment_id: meta.attachment_id });
      fileErrors.push({ name: file.name, key: 'leave.errGeneric' });
    }
  }
  revalidatePath('/portal/leave');
  return { error: null, fileErrors };
}

export async function cancelLeave(leaveId: string): Promise<LeaveResult> {
  if (!z.string().uuid().safeParse(leaveId).success) return fail('leave.errGeneric');
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('cancel_student_leave', { p_leave_id: leaveId });
  if (error) return fail('leave.errGeneric');
  revalidatePath('/portal/leave');
  return { error: null, fileErrors: [] };
}
