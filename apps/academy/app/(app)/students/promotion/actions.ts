'use server';

import { revalidatePath } from 'next/cache';
import { startRolloverSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type RolloverRunSummary = {
  run_id: string;
  status: 'pending' | 'running' | 'completed';
  total_count: number;
  processed_count: number;
  created_count: number;
  already_existing_count: number;
  promoted_count: number;
  retained_count: number;
  passed_out_count: number;
  held_count: number;
  is_no_op: boolean | null;
  started_at: string | null;
  finished_at: string | null;
};

export type RolloverDecisionRow = {
  id: string;
  studentId: string;
  grNumber: string;
  studentName: string;
  sourceClassName: string;
  decision: 'promote' | 'retain' | 'pass_out' | 'hold';
  targetClassName: string | null;
  errorCode: string | null;
  processedAt: string | null;
};

export type StartRolloverState = { error: string | null; summary: RolloverRunSummary | null };

// FR-A06: snapshot the decision set for a campus/from-session/to-session.
// Writes nothing to student/enrolment yet — start_session_rollover() only
// creates the run + one session_rollover_decision row per eligible
// enrolment, defaulting to promote/hold/pass_out per class_level.ordinal.
export async function startRollover(_prev: StartRolloverState, formData: FormData): Promise<StartRolloverState> {
  const parsed = startRolloverSchema.safeParse({
    campusId: formData.get('campusId'),
    fromSessionId: formData.get('fromSessionId'),
    toSessionId: formData.get('toSessionId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', summary: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('start_session_rollover', {
    p_campus_id: parsed.data.campusId,
    p_from_session_id: parsed.data.fromSessionId,
    p_to_session_id: parsed.data.toSessionId,
  });
  if (error) {
    if (error.message.includes('SAME_SESSION')) return { error: 'The source and target sessions must be different.', summary: null };
    if (error.message.includes('FROM_SESSION_NOT_FOUND')) return { error: 'The source session could not be found.', summary: null };
    if (error.message.includes('TO_SESSION_NOT_FOUND')) return { error: 'The target session could not be found.', summary: null };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'This campus could not be found.', summary: null };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to start a rollover.', summary: null };
    return { error: 'Could not start the rollover.', summary: null };
  }

  return { error: null, summary: data as RolloverRunSummary };
}

export type FetchDecisionsResult = { error: string | null; decisions: RolloverDecisionRow[] };

// Backs both the initial decision list render and every refresh after an
// override or a batch call — v_rollover_decision_detail is campus-scoped
// RLS, joined through session_rollover_run.
export async function fetchRolloverDecisions(runId: string): Promise<FetchDecisionsResult> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase
    .from('v_rollover_decision_detail')
    .select('id, student_id, gr_number, student_name, source_class_name, decision, target_class_name, error_code, processed_at')
    .eq('run_id', runId)
    .order('student_name')
    .limit(500);
  if (error) return { error: 'Could not load the decision list.', decisions: [] };

  // v_rollover_decision_detail's columns are typed nullable (a generic view
  // trait of the generator), but id/student_id/gr_number/student_name/
  // source_class_name/decision are all NOT NULL on the underlying tables —
  // only target_class_name/error_code/processed_at are genuinely optional.
  return {
    error: null,
    decisions: (data ?? [])
      .filter((d) => d.id !== null && d.student_id !== null && d.decision !== null)
      .map((d) => ({
        id: d.id as string,
        studentId: d.student_id as string,
        grNumber: d.gr_number ?? '',
        studentName: d.student_name ?? '',
        sourceClassName: d.source_class_name ?? '',
        decision: d.decision as RolloverDecisionRow['decision'],
        targetClassName: d.target_class_name,
        errorCode: d.error_code,
        processedAt: d.processed_at,
      })),
  };
}

export type OverrideDecisionState = { error: string | null };

// FR-A06: per-student override, before that decision has been processed.
export async function overrideRolloverDecision(
  runId: string,
  studentId: string,
  decision: 'promote' | 'retain' | 'pass_out'
): Promise<OverrideDecisionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_rollover_decision', { p_run_id: runId, p_student_id: studentId, p_decision: decision });
  if (error) {
    if (error.message.includes('DECISION_ALREADY_PROCESSED')) return { error: 'This student was already processed and can no longer be changed.' };
    if (error.message.includes('RUN_ALREADY_COMPLETED')) return { error: 'This rollover has already completed.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to change this decision.' };
    return { error: 'Could not update the decision.' };
  }
  return { error: null };
}

// Bulk variant of the same override, for "select several, mark them retain
// / pass-out at once" — set_rollover_decisions_bulk() just loops the
// single-student RPC server-side under one call.
export async function overrideRolloverDecisionsBulk(
  runId: string,
  studentIds: string[],
  decision: 'promote' | 'retain' | 'pass_out'
): Promise<OverrideDecisionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_rollover_decisions_bulk', { p_run_id: runId, p_student_ids: studentIds, p_decision: decision });
  if (error) return { error: 'Could not update the selected decisions.' };
  return { error: null };
}

export type AdvanceBatchResult = { error: string | null; summary: (RolloverRunSummary & { batch_processed: number }) | null };

// FR-A06: the resumable worker step. There is no background worker/cron
// locally (same constraint every batch-style FR in this codebase has hit)
// — the client drives this repeatedly until status flips to 'completed'.
// Each call is its own independent RPC/transaction, so calling it again
// after the browser tab (or the whole process) was closed mid-run resumes
// from exactly where the last successful call left off, with no client-
// side checkpoint needed.
export async function advanceRolloverBatch(runId: string): Promise<AdvanceBatchResult> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('execute_rollover_batch', { p_run_id: runId, p_limit: 200 });
  if (error) return { error: 'Could not advance the rollover.', summary: null };

  const summary = data as RolloverRunSummary & { batch_processed: number };
  if (summary.status === 'completed') {
    revalidatePath('/students/promotion');
    revalidatePath('/students');
  }
  return { error: null, summary };
}
