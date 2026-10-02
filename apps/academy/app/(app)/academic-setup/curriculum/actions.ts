'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type UpsertClassSubjectState = { error: string | null };

// Map a subject onto a class (optionally within a stream) with its weekly period count.
export async function upsertClassSubject(_prev: UpsertClassSubjectState, formData: FormData): Promise<UpsertClassSubjectState> {
  const campusId = formData.get('campusId');
  const sessionId = formData.get('sessionId');
  const classLevelId = formData.get('classLevelId');
  const subjectId = formData.get('subjectId');
  const weeklyPeriods = Number(formData.get('weeklyPeriods'));
  const isCompulsory = formData.get('isCompulsory') === 'on';
  const electiveBucket = formData.get('electiveBucket');
  const choosen = formData.get('chooseN');

  if (
    typeof campusId !== 'string' ||
    typeof sessionId !== 'string' ||
    typeof classLevelId !== 'string' ||
    typeof subjectId !== 'string' ||
    !Number.isFinite(weeklyPeriods)
  ) {
    return { error: 'Fill in every field.' };
  }

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_class_subject', {
    p_campus_id: campusId,
    p_session_id: sessionId,
    p_class_level_id: classLevelId,
    p_subject_id: subjectId,
    p_weekly_periods: weeklyPeriods,
    p_is_compulsory: isCompulsory,
    p_elective_bucket: electiveBucket ? Number(electiveBucket) : undefined,
    p_choose_n: choosen ? Number(choosen) : undefined,
  });

  if (error) {
    if (error.message.includes('WEEKLY_PERIODS_REQUIRED')) return { error: 'Weekly periods must be at least 1.' };
    if (error.message.includes('WEEKLY_PERIODS_OUT_OF_RANGE')) return { error: 'Weekly periods cannot exceed 12.' };
    if (error.message.includes('ELECTIVE_BUCKET_REQUIRED')) return { error: 'Elective subjects need a bucket number.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to edit the curriculum for this campus.' };
    if (error.message.includes('SESSION_NOT_FOUND')) return { error: 'This session could not be found.' };
    if (error.message.includes('CLASS_LEVEL_NOT_FOUND')) return { error: 'This class could not be found.' };
    if (error.message.includes('SUBJECT_NOT_FOUND')) return { error: 'This subject could not be found.' };
    if (error.message.includes('STREAM_NOT_FOUND')) return { error: 'This stream could not be found.' };
    return { error: 'Could not save the subject mapping.' };
  }

  revalidatePath('/academic-setup/curriculum');
  return { error: null };
}

export async function deleteClassSubject(id: string): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await (supabase.rpc as any)('delete_class_subject', { p_id: id });

  if (error) {
    if (error.message.includes('FORBIDDEN')) {
      return { error: 'You do not have permission to remove subjects from the curriculum.' };
    }
    return { error: error.message || 'Could not remove subject from curriculum.' };
  }

  revalidatePath('/academic-setup/curriculum');
  return { error: null };
}

export type CopyMapState = { error: string | null; result: { created: number; skipped: number } | null };

export async function copyClassSubjectMap(
  fromClassLevelId: string,
  toClassLevelId: string,
  sessionId: string,
  campusId: string,
): Promise<CopyMapState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('copy_class_subject_map', {
    p_from_class_level_id: fromClassLevelId,
    p_to_class_level_id: toClassLevelId,
    p_session_id: sessionId,
    p_campus_id: campusId,
  });

  if (error) return { error: 'Could not copy the curriculum map.', result: null };

  revalidatePath('/academic-setup/curriculum');
  return { error: null, result: data as { created: number; skipped: number } };
}

// Copy a class's full curriculum across multiple target classes at once (e.g. Class 1 -> Classes 2, 3, 4, 5)
export async function copyCurriculumToMultipleClasses(
  fromClassLevelId: string,
  toClassLevelIds: string[],
  sessionId: string,
  campusId: string,
): Promise<{ error: string | null; created: number; skipped: number }> {
  if (!toClassLevelIds.length) {
    return { error: 'Select at least one destination class.', created: 0, skipped: 0 };
  }

  const supabase = await supabaseServer();
  let totalCreated = 0;
  let totalSkipped = 0;

  for (const toId of toClassLevelIds) {
    const { data, error } = await supabase.rpc('copy_class_subject_map', {
      p_from_class_level_id: fromClassLevelId,
      p_to_class_level_id: toId,
      p_session_id: sessionId,
      p_campus_id: campusId,
    });

    if (error) {
      return { error: 'Could not copy curriculum to all selected classes.', created: totalCreated, skipped: totalSkipped };
    }

    const res = data as { created: number; skipped: number };
    totalCreated += res?.created ?? 0;
    totalSkipped += res?.skipped ?? 0;
  }

  revalidatePath('/academic-setup/curriculum');
  return { error: null, created: totalCreated, skipped: totalSkipped };
}

// Bulk assign a subject to multiple classes in one click (e.g. English, 6 periods, to Classes 1-5)
export async function assignSubjectToMultipleClasses({
  campusId,
  sessionId,
  classLevelIds,
  subjectId,
  weeklyPeriods,
  isCompulsory,
  electiveBucket,
}: {
  campusId: string;
  sessionId: string;
  classLevelIds: string[];
  subjectId: string;
  weeklyPeriods: number;
  isCompulsory: boolean;
  electiveBucket?: number;
}): Promise<{ error: string | null; count?: number }> {
  if (!classLevelIds.length) {
    return { error: 'Select at least one class.' };
  }

  const supabase = await supabaseServer();
  let assignedCount = 0;

  for (const classId of classLevelIds) {
    const { error } = await supabase.rpc('upsert_class_subject', {
      p_campus_id: campusId,
      p_session_id: sessionId,
      p_class_level_id: classId,
      p_subject_id: subjectId,
      p_weekly_periods: weeklyPeriods,
      p_is_compulsory: isCompulsory,
      p_elective_bucket: electiveBucket,
    });

    if (error) {
      return { error: `Failed to map subject: ${error.message}` };
    }
    assignedCount++;
  }

  revalidatePath('/academic-setup/curriculum');
  return { error: null, count: assignedCount };
}
