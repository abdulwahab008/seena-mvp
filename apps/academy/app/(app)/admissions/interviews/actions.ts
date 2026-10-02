'use server';

import { revalidatePath } from 'next/cache';
import { bookInterviewSchema, submitScorecardSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type BookState = { error: string | null; needsConfirmation: boolean };

// FR-B13: book an interview slot against a panel member's calendar. The
// exclusion constraint inside admission_interview is the real authority
// against double-booking; book_interview() also names the conflicting
// application when it refuses. A PANEL_ON_LEAVE refusal is a soft block —
// the caller resubmits with confirmDespiteLeave to proceed anyway.
export async function bookInterview(_prev: BookState, formData: FormData): Promise<BookState> {
  const parsed = bookInterviewSchema.safeParse({
    applicationId: formData.get('applicationId'),
    panelUserId: formData.get('panelUserId'),
    startsAt: formData.get('startsAt'),
    endsAt: formData.get('endsAt'),
    venue: formData.get('venue') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', needsConfirmation: false };

  const confirmDespiteLeave = formData.get('confirmDespiteLeave') === 'true';

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('book_interview', {
    p_application_id: parsed.data.applicationId,
    p_panel_user_id: parsed.data.panelUserId,
    p_starts_at: parsed.data.startsAt,
    p_ends_at: parsed.data.endsAt,
    p_venue: parsed.data.venue,
    p_confirm_despite_leave: confirmDespiteLeave,
  });
  if (error) {
    if (error.message.includes('PANEL_ON_LEAVE')) {
      return { error: 'This panel member has approved leave covering this window.', needsConfirmation: true };
    }
    if (error.message.includes('PANEL_MEMBER_BUSY')) return { error: 'This panel member already has a booking that overlaps this window.', needsConfirmation: false };
    if (error.message.includes('END_MUST_BE_AFTER_START')) return { error: 'End time must be after the start time.', needsConfirmation: false };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to book an interview.', needsConfirmation: false };
    return { error: 'Could not book the interview.', needsConfirmation: false };
  }

  revalidatePath('/admissions/interviews');
  return { error: null, needsConfirmation: false };
}

export async function cancelInterview(interviewId: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('cancel_interview', { p_interview_id: interviewId });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to cancel this interview.' };
    return { error: 'Could not cancel the interview.' };
  }

  revalidatePath('/admissions/interviews');
  return { error: null };
}

export type NotificationPayload = {
  interview_id: string;
  application_no: string | null;
  phone: string | null;
  channel: 'whatsapp' | 'sms';
  starts_at: string;
  ends_at: string;
  venue: string | null;
};

export async function fetchInterviewNotificationPayload(
  interviewId: string
): Promise<{ error: string | null; payload: NotificationPayload | null }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_build_interview_notification_payload', { p_interview_id: interviewId });
  if (error) return { error: 'Could not load the notification preview.', payload: null };
  return { error: null, payload: data as NotificationPayload };
}

// FR-B14: submit (or, for a Principal, correct) a structured interview
// scorecard. All the business rules — every criterion scored,
// justification required only when the recommendation overrides the
// applicant's merit rank, read-only once submitted except to a Principal
// — are enforced inside submit_interview_scorecard() itself.
export async function submitScorecard(_prev: { error: string | null }, formData: FormData): Promise<{ error: string | null }> {
  const scoresRaw = formData.get('scores');
  let scores: unknown;
  try {
    scores = JSON.parse(typeof scoresRaw === 'string' ? scoresRaw : '{}');
  } catch {
    return { error: 'Invalid scores.' };
  }

  const parsed = submitScorecardSchema.safeParse({
    interviewId: formData.get('interviewId'),
    scores,
    recommendation: formData.get('recommendation'),
    justification: formData.get('justification') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('submit_interview_scorecard', {
    p_interview_id: parsed.data.interviewId,
    p_scores: Object.entries(parsed.data.scores).map(([criterion, score]) => ({ criterion, score })),
    p_recommendation: parsed.data.recommendation,
    p_justification: parsed.data.justification,
  });
  if (error) {
    if (error.message.includes('JUSTIFICATION_REQUIRED')) {
      return { error: 'This recommendation overrides the merit rank — a justification of at least 20 characters is required.' };
    }
    if (error.message.includes('MISSING_CRITERIA')) return { error: 'Every criterion must be scored.' };
    if (error.message.includes('SCORECARD_LOCKED')) return { error: 'This scorecard is already submitted — only a Principal can edit it.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to submit a scorecard.' };
    return { error: 'Could not submit the scorecard.' };
  }

  revalidatePath('/admissions/interviews');
  return { error: null };
}

export type Scorecard = {
  interview_id: string;
  panel_name: string;
  recommendation: string;
  justification: string | null;
  scores: Record<string, number>;
};
export type ScorecardSummary = { application_id: string; scorecards: Scorecard[]; mean_by_criterion: Record<string, number> };

export async function fetchScorecardSummary(applicationId: string): Promise<{ error: string | null; summary: ScorecardSummary | null }> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_scorecard_summary', { p_application_id: applicationId });
  if (error) return { error: 'Could not load the scorecards.', summary: null };
  return { error: null, summary: data as ScorecardSummary };
}
