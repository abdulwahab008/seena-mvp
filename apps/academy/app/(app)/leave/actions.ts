'use server';

import { revalidatePath } from 'next/cache';
import { applyLeaveSchema, decideLeaveSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ApplyLeaveState = { error: string | null };

// FR-D11: apply for leave. Authorization (self or HR/Principal/Owner),
// the balance check and the working-day calculation all live inside
// apply_for_leave() — this action only shapes the client-facing error.
export async function applyLeave(staffId: string, _prev: ApplyLeaveState, formData: FormData): Promise<ApplyLeaveState> {
  const parsed = applyLeaveSchema.safeParse({
    leaveTypeId: formData.get('leaveTypeId'),
    fromDate: formData.get('fromDate'),
    toDate: formData.get('toDate'),
    isHalfDay: formData.get('isHalfDay') === 'on',
    reason: formData.get('reason') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('apply_for_leave', {
    p_staff_id: staffId,
    p_leave_type_id: parsed.data.leaveTypeId,
    p_from_date: parsed.data.fromDate,
    p_to_date: parsed.data.toDate,
    p_is_half_day: parsed.data.isHalfDay,
    p_reason: parsed.data.reason,
  });
  if (error) {
    if (error.message.includes('INSUFFICIENT_BALANCE')) return { error: 'Not enough leave balance for these dates.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to apply for leave.' };
    return { error: 'Could not submit the leave application.' };
  }

  revalidatePath('/leave');
  return { error: null };
}

export type CancelLeaveState = { error: string | null };

// FR-D13 AC4: cancel an already-approved application. cancel_leave_
// application() reverses its ledger consumption and its own trigger
// flags (never deletes) any substitution built against the cancelled
// dates — this action only shapes the client-facing error.
export async function cancelLeave(applicationId: string): Promise<CancelLeaveState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('cancel_leave_application', { p_application_id: applicationId });
  if (error) {
    if (error.message.includes('APPLICATION_NOT_APPROVED')) return { error: 'Only an approved application can be cancelled.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to cancel this application.' };
    return { error: 'Could not cancel this application.' };
  }

  revalidatePath('/leave');
  revalidatePath('/academic-setup/substitutions');
  return { error: null };
}

export type DecideLeaveState = { error: string | null };

function mapDecideError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You do not have permission to decide this application.';
  if (message.includes('STEP_ESCALATED')) return 'This request has escalated to Owner — you can no longer decide it.';
  if (message.includes('APPLICATION_NOT_PENDING')) return 'This application was already decided.';
  return 'Could not record the decision.';
}

// FR-D12: decide a pending application. Whether the application is on a
// configured approval chain or not was decided back in apply_for_leave() —
// advance_leave_approval() reports NO_PENDING_STEP when there is no chain
// step to act on, which is exactly when fn_decide_leave_application()'s
// single-step fallback (FR-D11) is the right call instead.
export async function decideLeave(_prev: DecideLeaveState, formData: FormData): Promise<DecideLeaveState> {
  const parsed = decideLeaveSchema.safeParse({
    applicationId: formData.get('applicationId'),
    decision: formData.get('decision'),
    comment: formData.get('comment') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error: chainError } = await supabase.rpc('advance_leave_approval', {
    p_application_id: parsed.data.applicationId,
    p_decision: parsed.data.decision,
    p_comment: parsed.data.comment,
  });

  if (chainError) {
    if (!chainError.message.includes('NO_PENDING_STEP')) return { error: mapDecideError(chainError.message) };

    const { error } = await supabase.rpc('fn_decide_leave_application', {
      p_application_id: parsed.data.applicationId,
      p_decision: parsed.data.decision,
      p_comment: parsed.data.comment,
    });
    if (error) return { error: mapDecideError(error.message) };
  }

  revalidatePath('/leave');
  return { error: null };
}
