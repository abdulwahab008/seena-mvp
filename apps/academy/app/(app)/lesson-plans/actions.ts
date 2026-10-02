'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { lessonPlanSchema, type LessonPlanInput } from '@/lib/validation';

type Result = { error: string | null };

function mapError(message: string): string {
  if (message.includes('LESSON_PLAN_EXISTS')) return 'A lesson plan already exists for this week';
  if (message.includes('TOPIC_NOT_IN_SYLLABUS')) return 'One of the topics is not in this subject\'s syllabus.';
  if (message.includes('FORBIDDEN')) return 'You are not assigned to this section and subject.';
  if (message.includes('TEXT_TOO_LONG')) return 'Objectives and resources can be at most 1000 characters.';
  return 'Something went wrong. Please try again.';
}

export async function createPlan(input: LessonPlanInput): Promise<Result> {
  const p = lessonPlanSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_lesson_plan', {
    p_section_id: p.data.sectionId, p_subject_id: p.data.subjectId, p_week_start: p.data.weekStart,
    p_objectives: p.data.objectives || undefined, p_resources: p.data.resources || undefined, p_topic_ids: p.data.topicIds,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/lesson-plans');
  return { error: null };
}

export async function setPlanStatus(planId: string, status: 'planned' | 'in_progress' | 'completed'): Promise<Result> {
  if (!z.string().uuid().safeParse(planId).success) return { error: 'Invalid plan.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_lesson_plan_status', { p_plan_id: planId, p_status: status });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/lesson-plans');
  return { error: null };
}
