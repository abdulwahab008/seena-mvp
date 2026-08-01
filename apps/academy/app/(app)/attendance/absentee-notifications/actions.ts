'use server';

import { dispatchAbsenteeNotificationsSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type NotificationRow = {
  enrolmentId: string;
  studentName: string;
  grNumber: string;
  status: string;
  language: string;
  recipientMsisdn: string | null;
  costPaisa: number;
};
export type SectionNotMarked = { sectionId: string; sectionLabel: string };
export type LoadAbsenteeState = { error: string | null; rows: NotificationRow[]; sectionsNotMarked: SectionNotMarked[] };

export async function loadAbsenteeNotifications(campusId: string, date: string): Promise<LoadAbsenteeState> {
  const supabase = await supabaseServer();
  const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

  const [{ data: rows }, { data: notMarked }] = await Promise.all([
    supabase
      .from('attendance_notification')
      .select('enrolment_id, status, language, recipient_msisdn, cost_paisa, enrolment(student(name_en, gr_number))')
      .eq('campus_id', campusId)
      .eq('notification_date', date),
    supabase.rpc('sections_not_marked', { p_campus_id: campusId, p_date: date }),
  ]);

  return {
    error: null,
    rows: (rows ?? []).map((r) => ({
      enrolmentId: r.enrolment_id,
      studentName: one(one(r.enrolment)?.student)?.name_en ?? 'Unknown',
      grNumber: one(one(r.enrolment)?.student)?.gr_number ?? '',
      status: r.status,
      language: r.language,
      recipientMsisdn: r.recipient_msisdn,
      costPaisa: r.cost_paisa,
    })),
    sectionsNotMarked: (notMarked ?? []).map((s: { section_id: string; section_label: string }) => ({
      sectionId: s.section_id,
      sectionLabel: s.section_label,
    })),
  };
}

export type RunDispatchState = { error: string | null; queued: number | null; skippedNoContact: number | null; sectionsNotMarked: number | null };

// FR-G12: dispatch_absentee_notifications() itself enforces the
// Owner/Principal role and is idempotent per (enrolment_id,
// notification_date, channel) — re-running the same date is always
// safe, and is exactly how an office re-runs a job manually (AC3).
export async function runAbsenteeDispatch(_prev: RunDispatchState, formData: FormData): Promise<RunDispatchState> {
  const parsed = dispatchAbsenteeNotificationsSchema.safeParse({
    campusId: formData.get('campusId'),
    date: formData.get('date'),
  });
  if (!parsed.success)
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input.', queued: null, skippedNoContact: null, sectionsNotMarked: null };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('dispatch_absentee_notifications', {
    p_campus_id: parsed.data.campusId,
    p_date: parsed.data.date,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN'))
      return { error: 'Only an Owner or Principal can run absentee notifications.', queued: null, skippedNoContact: null, sectionsNotMarked: null };
    if (error.message.includes('CAMPUS_NOT_FOUND'))
      return { error: 'Campus not found.', queued: null, skippedNoContact: null, sectionsNotMarked: null };
    return { error: 'Could not run absentee notifications.', queued: null, skippedNoContact: null, sectionsNotMarked: null };
  }

  const result = data as { queued: number; skipped_no_contact: number; sections_not_marked: number };
  return { error: null, queued: result.queued, skippedNoContact: result.skipped_no_contact, sectionsNotMarked: result.sections_not_marked };
}
