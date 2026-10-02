'use server';

import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
import { z } from 'zod';
import { clearItemSchema, initiateExitSchema, waiveItemSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ExitState = { error: string | null; message?: string | null; exitId?: string | null };

function mapError(message: string): string {
  if (message.startsWith('CLEARANCE_OUTSTANDING') || message.includes('CLEARANCE_OUTSTANDING')) {
    const names = message.split('CLEARANCE_OUTSTANDING:')[1]?.trim();
    return `Cannot complete the exit yet. Still outstanding: ${names ?? 'clearance items'}.`;
  }
  if (message.includes('NOT_ITEM_OWNER')) return 'Only the department that owns this item can mark it cleared. HR can record a waiver with a reason instead.';
  if (message.includes('WAIVER_REASON_TOO_SHORT')) return 'A waiver needs a reason of at least 10 characters.';
  if (message.includes('LAST_WORKING_DATE_NOT_REACHED')) return 'The exit cannot be completed before the last working date; access is cut when it is.';
  if (message.includes('EXIT_ALREADY_OPEN')) return 'This person already has an exit in progress.';
  if (message.includes('ALREADY_EXITED')) return 'This person has already left.';
  if (message.includes('EXIT_ALREADY_COMPLETED')) return 'This exit is already completed.';
  if (message.includes('LAST_WORKING_DATE_BEFORE_NOTICE')) return 'The last working date is before the notice date.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  if (message.includes('EXIT_NOT_FOUND') || message.includes('ITEM_NOT_FOUND') || message.includes('STAFF_NOT_FOUND')) return 'Record not found.';
  return 'Something went wrong. Please try again.';
}

const blank = (v: FormDataEntryValue | null) => (typeof v === 'string' && v.trim() !== '' ? v : undefined);

export async function initiateExit(_prev: ExitState, formData: FormData): Promise<ExitState> {
  const p = initiateExitSchema.safeParse({
    staffId: formData.get('staffId'),
    exitType: formData.get('exitType'),
    noticeDate: blank(formData.get('noticeDate')),
    lastWorkingDate: formData.get('lastWorkingDate'),
    reason: blank(formData.get('reason')),
  });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('initiate_staff_exit', {
    p_staff_id: p.data.staffId,
    p_exit_type: p.data.exitType,
    p_notice_date: p.data.noticeDate || undefined,
    p_last_working_date: p.data.lastWorkingDate,
    p_reason: p.data.reason,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/exits');
  revalidatePath(`/staff/${p.data.staffId}`);
  // Redirect from the server action itself: the staff profile this form lives on re-renders (revalidatePath)
  // in the same response and swaps the form for the "exit in progress" link, so a client-side effect that
  // waited for the success state to push to the exit page would never run — the HR user would stay on the
  // profile with no indication of the notice shortfall.
  redirect(`/staff/exits/${data as string}`);
}

export async function clearItem(_prev: ExitState, formData: FormData): Promise<ExitState> {
  const p = clearItemSchema.safeParse({ exitId: formData.get('exitId'), itemCode: formData.get('itemCode') });
  if (!p.success) return { error: 'Invalid item.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('clear_exit_item', { p_exit_id: p.data.exitId, p_item_code: p.data.itemCode });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/exits/${p.data.exitId}`);
  revalidatePath('/staff/exits');
  return { error: null, message: 'Marked cleared.' };
}

export async function waiveItem(_prev: ExitState, formData: FormData): Promise<ExitState> {
  const p = waiveItemSchema.safeParse({ exitId: formData.get('exitId'), itemCode: formData.get('itemCode'), reason: formData.get('reason') });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('waive_exit_item', { p_exit_id: p.data.exitId, p_item_code: p.data.itemCode, p_reason: p.data.reason });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/exits/${p.data.exitId}`);
  return { error: null, message: 'Waiver recorded.' };
}

export async function completeExit(_prev: ExitState, formData: FormData): Promise<ExitState> {
  const id = z.string().uuid().safeParse(formData.get('exitId'));
  if (!id.success) return { error: 'Invalid exit.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('complete_staff_exit', { p_exit_id: id.data });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/exits/${id.data}`);
  revalidatePath('/staff/exits');
  return { error: null, message: 'Exit completed. Access has been revoked.' };
}
