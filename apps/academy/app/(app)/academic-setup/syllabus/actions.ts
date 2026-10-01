'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { BOARDS, syllabusTopicSchema, syllabusUnitSchema, type SyllabusTopicInput, type SyllabusUnitInput } from '@/lib/validation';

type Result = { error: string | null };
const scope = z.object({
  campusId: z.string().uuid(),
  sessionId: z.string().uuid(),
  classLevelId: z.string().uuid(),
  subjectId: z.string().uuid(),
  board: z.enum(BOARDS),
});
export type SyllabusScope = z.infer<typeof scope>;

function mapError(message: string): string {
  const known: [string, string][] = [
    ['FORBIDDEN', 'Only a Principal, Exam Controller or Owner can change the syllabus.'],
    ['TARGET_SYLLABUS_EXISTS', 'The target session already has a syllabus for this class and subject.'],
    ['NOTHING_TO_CLONE', 'There is no syllabus in the source session to copy.'],
    ['SYLLABUS_ALREADY_EXISTS', 'A syllabus already exists for this class, subject and board.'],
    ['ORDER_MUST_LIST_EVERY_UNIT', 'The new order must list every unit.'],
  ];
  return known.find(([k]) => message.includes(k))?.[1] ?? 'Something went wrong. Please try again.';
}
const monthStart = (m: string | undefined) => (m ? `${m}-01` : undefined);

async function run(fn: (s: Awaited<ReturnType<typeof supabaseServer>>) => PromiseLike<{ error: { message: string } | null }>): Promise<Result> {
  const supabase = await supabaseServer();
  const { error } = await fn(supabase);
  if (error) return { error: mapError(error.message) };
  revalidatePath('/academic-setup/syllabus');
  return { error: null };
}

export async function addUnit(rawScope: SyllabusScope, input: SyllabusUnitInput): Promise<Result> {
  const s = scope.safeParse(rawScope);
  const u = syllabusUnitSchema.safeParse(input);
  if (!s.success || !u.success) return { error: u.success ? 'Invalid selection.' : (u.error.issues[0]?.message ?? 'Invalid input.') };
  return run((db) =>
    db.rpc('add_syllabus_unit', {
      p_campus_id: s.data.campusId, p_session_id: s.data.sessionId, p_class_level_id: s.data.classLevelId, p_subject_id: s.data.subjectId, p_board: s.data.board,
      p_title: u.data.title, p_title_ur: u.data.titleUr, p_planned_periods: u.data.plannedPeriods, p_target_month: monthStart(u.data.targetMonth),
    }),
  );
}

export async function addTopic(unitId: string, input: SyllabusTopicInput): Promise<Result> {
  const t = syllabusTopicSchema.safeParse(input);
  if (!z.string().uuid().safeParse(unitId).success || !t.success) return { error: t.success ? 'Invalid unit.' : (t.error.issues[0]?.message ?? 'Invalid input.') };
  return run((db) => db.rpc('add_syllabus_topic', { p_unit_id: unitId, p_title: t.data.title, p_title_ur: t.data.titleUr, p_planned_periods: t.data.plannedPeriods }));
}

export async function reorderUnits(unitIds: string[]): Promise<Result> {
  if (!z.array(z.string().uuid()).min(1).safeParse(unitIds).success) return { error: 'Invalid order.' };
  return run((db) => db.rpc('reorder_syllabus_units', { p_unit_ids: unitIds }));
}

export async function deleteUnit(unitId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(unitId).success) return { error: 'Invalid unit.' };
  return run((db) => db.rpc('delete_syllabus_unit', { p_unit_id: unitId }));
}

export async function deleteTopic(topicId: string): Promise<Result> {
  if (!z.string().uuid().safeParse(topicId).success) return { error: 'Invalid topic.' };
  return run((db) => db.rpc('delete_syllabus_topic', { p_topic_id: topicId }));
}

export async function cloneSyllabus(input: { campusId: string; fromSessionId: string; toSessionId: string; classLevelId: string; subjectId: string }): Promise<Result & { cloned?: number }> {
  const p = z.object({ campusId: z.string().uuid(), fromSessionId: z.string().uuid(), toSessionId: z.string().uuid('Choose the target session'), classLevelId: z.string().uuid(), subjectId: z.string().uuid() }).safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('clone_syllabus_to_session', { p_campus_id: p.data.campusId, p_from_session: p.data.fromSessionId, p_to_session: p.data.toSessionId, p_class_level_id: p.data.classLevelId, p_subject_id: p.data.subjectId });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/academic-setup/syllabus');
  return { error: null, cloned: typeof data === 'number' ? data : undefined };
}
