'use server';

import { revalidatePath } from 'next/cache';
import { issueDisciplinarySchema, reinstateSchema, supersedeDisciplinarySchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type DisciplineState = { error: string | null; message?: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You are not allowed to do that.';
  if (message.includes('STAFF_NOT_FOUND')) return 'Staff member not found.';
  if (message.includes('RECORD_NOT_FOUND')) return 'That record was not found.';
  if (message.includes('ALREADY_SUPERSEDED')) return 'That record has already been corrected or answered; work from the latest entry.';
  if (message.includes('RECORD_NOT_CORRECTABLE')) return 'A reinstatement cannot be corrected.';
  if (message.includes('RESPONSE_DAYS_REQUIRED')) return 'Enter the response deadline in days (1 to 60).';
  if (message.includes('SUSPENSION_DATES_INVALID')) return 'Enter a valid suspension start and end date.';
  if (message.includes('RESPONSE_EMPTY')) return 'The response cannot be empty.';
  return 'Something went wrong. Please try again.';
}

const blank = (v: FormDataEntryValue | null) => (typeof v === 'string' && v.trim() !== '' ? v : undefined);

export async function issueDisciplinaryAction(_prev: DisciplineState, formData: FormData): Promise<DisciplineState> {
  const p = issueDisciplinarySchema.safeParse({
    staffId: formData.get('staffId'),
    actionType: formData.get('actionType'),
    description: formData.get('description'),
    responseDays: blank(formData.get('responseDays')),
    suspendFrom: blank(formData.get('suspendFrom')),
    suspendTo: blank(formData.get('suspendTo')),
  });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('issue_disciplinary_action', {
    p_staff_id: p.data.staffId,
    p_action_type: p.data.actionType,
    p_description: p.data.description,
    p_response_days: p.data.actionType === 'show_cause' ? p.data.responseDays : undefined,
    p_suspend_from: p.data.actionType === 'suspension' ? p.data.suspendFrom || undefined : undefined,
    p_suspend_to: p.data.actionType === 'suspension' ? p.data.suspendTo || undefined : undefined,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath(`/staff/${p.data.staffId}`);
  revalidatePath('/staff/discipline');
  return { error: null, message: 'Recorded. It can no longer be edited or deleted; corrections are added as new entries.' };
}

// A correction, the staff member's response, or an outcome: always a NEW row
// that references the one it replaces.
export async function supersedeDisciplinaryRecord(_prev: DisciplineState, formData: FormData): Promise<DisciplineState> {
  const p = supersedeDisciplinarySchema.safeParse({
    recordId: formData.get('recordId'),
    description: blank(formData.get('description')),
    staffResponse: blank(formData.get('staffResponse')),
    outcome: blank(formData.get('outcome')),
    suspendFrom: blank(formData.get('suspendFrom')),
    suspendTo: blank(formData.get('suspendTo')),
  });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  if (!p.data.description && !p.data.staffResponse && !p.data.outcome && !p.data.suspendFrom) return { error: 'Enter a correction, a response or an outcome.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('supersede_disciplinary_record', {
    p_supersedes_id: p.data.recordId,
    p_description: p.data.description,
    p_staff_response: p.data.staffResponse,
    p_outcome: p.data.outcome,
    p_suspend_from: p.data.suspendFrom || undefined,
    p_suspend_to: p.data.suspendTo || undefined,
  });
  if (error) return { error: mapError(error.message) };
  const staffId = formData.get('staffId');
  if (typeof staffId === 'string') revalidatePath(`/staff/${staffId}`);
  revalidatePath('/staff/discipline');
  return { error: null, message: 'Added as a new entry.' };
}

export async function reinstateStaff(_prev: DisciplineState, formData: FormData): Promise<DisciplineState> {
  const p = reinstateSchema.safeParse({ recordId: formData.get('recordId'), note: blank(formData.get('note')) });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reinstate_suspended_staff', { p_suspension_disciplinary_id: p.data.recordId, p_note: p.data.note ?? '' });
  if (error) return { error: mapError(error.message) };
  const staffId = formData.get('staffId');
  if (typeof staffId === 'string') revalidatePath(`/staff/${staffId}`);
  return { error: null, message: 'Suspension lifted.' };
}
