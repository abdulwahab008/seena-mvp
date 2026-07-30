'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

export type UpsertClassSubjectState = { error: string | null };

// FR-E06: map a subject onto a class (optionally within a stream) with its
// weekly period count. Authorization and every business rule (weekly
// periods required, elective subjects need a bucket) are enforced inside
// upsert_class_subject() itself.
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
    if (error.message.includes('ELECTIVE_BUCKET_REQUIRED')) return { error: 'Elective subjects need a bucket number.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to edit the curriculum for this campus.' };
    return { error: 'Could not save the subject mapping.' };
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
