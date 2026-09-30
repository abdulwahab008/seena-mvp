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

export async function initializeStandardLeavePolicies(): Promise<{ error: string | null; count?: number }> {
  const supabase = await supabaseServer();
  const { data, error } = await (supabase.rpc as any)('initialize_school_leave_policies');
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only owners, principals, or HR managers can initialize leave policies.' };
    return { error: error.message || 'Could not initialize leave policies.' };
  }
  revalidatePath('/leave');
  return { error: null, count: (data as any)?.leave_types_created ?? 0 };
}

export async function getStaffLeaveBalances(staffId: string): Promise<{
  error: string | null;
  leaveTypes?: { id: string; code: string; name_en: string }[];
  balances?: Record<string, number>;
}> {
  const supabase = await supabaseServer();
  const [{ data: types, error: tErr }, { data: ledger, error: lErr }] = await Promise.all([
    supabase.rpc('eligible_leave_types', { p_staff_id: staffId }),
    supabase.from('leave_ledger').select('leave_type_id, days').eq('staff_id', staffId),
  ]);
  if (tErr) return { error: tErr.message };
  if (lErr) return { error: lErr.message };
  const balances = (ledger ?? []).reduce<Record<string, number>>((acc, row) => {
    acc[row.leave_type_id] = (acc[row.leave_type_id] ?? 0) + Number(row.days);
    return acc;
  }, {});
  return { error: null, leaveTypes: types ?? [], balances };
}

export type SaveLeavePolicyInput = {
  id?: string;
  code?: string;
  name_en: string;
  entitlement_days: number;
  is_paid: boolean;
  doc_required_after_days?: number | null;
  is_active?: boolean;
  sync_active_staff?: boolean;
};

export async function saveSchoolLeavePolicy(input: SaveLeavePolicyInput): Promise<{ error: string | null; id?: string }> {
  const supabase = await supabaseServer();

  if (input.id) {
    // Update existing policy
    const { data, error } = await (supabase.rpc as any)('update_school_leave_policy', {
      p_id: input.id,
      p_name_en: input.name_en,
      p_entitlement_days: input.entitlement_days,
      p_is_paid: input.is_paid,
      p_doc_required_after_days: input.doc_required_after_days ?? null,
      p_is_active: input.is_active ?? true,
      p_sync_active_staff: input.sync_active_staff ?? true,
    });
    if (error) {
      if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to update leave policies.' };
      return { error: error.message || 'Could not update leave policy.' };
    }
    revalidatePath('/leave');
    return { error: null, id: (data as any)?.id };
  } else {
    // Create new custom policy
    if (!input.code || !input.code.trim()) {
      return { error: 'Policy code is required (e.g. STUDY, BEREAVEMENT).' };
    }
    const { data, error } = await (supabase.rpc as any)('create_custom_leave_policy', {
      p_code: input.code,
      p_name_en: input.name_en,
      p_entitlement_days: input.entitlement_days,
      p_is_paid: input.is_paid,
      p_doc_required_after_days: input.doc_required_after_days ?? null,
      p_grant_active_staff: input.sync_active_staff ?? true,
    });
    if (error) {
      if (error.message.includes('LEAVE_CODE_ALREADY_EXISTS')) return { error: `Policy code "${input.code}" already exists in this school.` };
      if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create leave policies.' };
      return { error: error.message || 'Could not create leave policy.' };
    }
    revalidatePath('/leave');
    return { error: null, id: (data as any)?.id };
  }
}

export async function toggleLeavePolicyActive(id: string, isActive: boolean): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await (supabase.rpc as any)('toggle_leave_policy_status', {
    p_id: id,
    p_is_active: isActive,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to change policy status.' };
    return { error: error.message || 'Could not update policy status.' };
  }
  revalidatePath('/leave');
  return { error: null };
}
