'use server';

import { revalidatePath } from 'next/cache';
import { createTimetableVersionSchema, upsertTimetableSlotSchema, publishTimetableSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

function mapError(message: string): string {
  if (message.startsWith('TEACHER_CLASH')) return `This teacher already has a clash — ${message.replace('TEACHER_CLASH: ', '')}.`;
  if (message.includes('TEACH_SCOPE_VIOLATION')) return 'TEACH_SCOPE_VIOLATION';
  if (message.includes('SUBJECT_NOT_OFFERED')) return 'This subject is not on the curriculum map for this class level/stream.';
  if (message.includes('VERSION_IMMUTABLE')) return 'This timetable version is no longer a draft and cannot be edited.';
  if (message.startsWith('QUOTA_SHORTFALL')) return message;
  if (message.includes('VERSION_NOT_DRAFT')) return 'This version has already been published.';
  if (message.includes('VERSION_RANGE_OVERLAP')) return 'This effective date overlaps another published version for this campus/session.';
  if (message.includes('VERSION_NOT_FOUND')) return 'Timetable version not found.';
  if (message.includes('SECTION_NOT_FOUND')) return 'Section not found.';
  if (message.includes('SESSION_NOT_FOUND')) return 'Session not found.';
  if (message.includes('CAMPUS_NOT_FOUND')) return 'Campus not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  return 'Something went wrong.';
}

export async function createTimetableVersion(
  campusId: string,
  sessionId: string,
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = createTimetableVersionSchema.safeParse({
    shift: formData.get('shift'),
    name: formData.get('name'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_timetable_version', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_shift: parsed.data.shift,
    p_name: parsed.data.name,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/timetable');
  return { error: null };
}

export type PrefillResult = { staffId: string | null; roomId: string | null } | null;

export async function getSlotPrefill(sectionId: string, subjectId: string): Promise<PrefillResult> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('prefill_slot_defaults', { p_section_id: sectionId, p_subject_id: subjectId }).single();
  if (error || !data) return null;
  return { staffId: data.staff_id, roomId: data.room_id };
}

export async function upsertTimetableSlot(
  versionId: string,
  sectionId: string,
  _prev: ActionState,
  formData: FormData,
): Promise<ActionState> {
  const parsed = upsertTimetableSlotSchema.safeParse({
    weekday: formData.get('weekday'),
    periodNo: formData.get('periodNo'),
    subjectId: formData.get('subjectId'),
    staffId: formData.get('staffId') || undefined,
    roomId: formData.get('roomId') || undefined,
    overrideReason: formData.get('overrideReason') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_timetable_slot', {
    p_version_id: versionId,
    p_section_id: sectionId,
    p_weekday: parsed.data.weekday,
    p_period_no: parsed.data.periodNo,
    p_subject_id: parsed.data.subjectId,
    p_staff_id: parsed.data.staffId,
    p_room_id: parsed.data.roomId,
    p_override_reason: parsed.data.overrideReason,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/timetable');
  return { error: null };
}

// FR-F09: publish_timetable() itself computes the shortfall/warning
// report and enforces the override-reason length — this action only
// shapes the client-facing error, returning the raw QUOTA_SHORTFALL
// message so the client can show it and offer the override field.
export async function publishTimetable(versionId: string, _prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = publishTimetableSchema.safeParse({
    effectiveFrom: formData.get('effectiveFrom'),
    overrideReason: formData.get('overrideReason') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('publish_timetable', {
    p_version_id: versionId,
    p_effective_from: parsed.data.effectiveFrom,
    p_override_reason: parsed.data.overrideReason,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/timetable');
  return { error: null };
}

export type CloneVersionState = { error: string | null; newVersionId: string | null };

// FR-F10: clone_timetable_version() copies every slot from a Published
// (or any) version into a fresh Draft — the starting point for a revision.
export async function cloneTimetableVersion(versionId: string): Promise<CloneVersionState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('clone_timetable_version', { p_version_id: versionId });
  if (error) return { error: mapError(error.message), newVersionId: null };

  revalidatePath('/academic-setup/timetable');
  return { error: null, newVersionId: data };
}

export async function clearTimetableSlot(
  versionId: string,
  sectionId: string,
  weekday: number,
  periodNo: number,
  _prev: ActionState,
  _formData: FormData,
): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('clear_timetable_slot', {
    p_version_id: versionId,
    p_section_id: sectionId,
    p_weekday: weekday,
    p_period_no: periodNo,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/academic-setup/timetable');
  return { error: null };
}
