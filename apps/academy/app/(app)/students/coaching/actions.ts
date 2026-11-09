'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError, toPaisa } from '@/lib/rpc-action';
import { batchSchema, coachingEnrolSchema, postMonthSchema } from './schema';

const ERRORS: [string, string][] = [
  ['FORBIDDEN', 'You do not have permission to manage coaching at this campus.'],
  ['BATCH_DUPLICATE', 'A batch with that name already exists at this campus.'],
  ['BATCH_INACTIVE', 'That batch is inactive. Reactivate it first.'],
  ['BATCH_NOT_FOUND', 'That batch no longer exists.'],
  ['STAFF_NOT_FOUND', 'Choose a teacher from the staff list.'],
  ['STUDENT_NOT_FOUND', 'No active student at this campus has that GR number.'],
  ['ALREADY_ENROLLED', 'That student is already in this batch.'],
  ['ALREADY_ENDED', 'That enrolment has already ended.'],
  ['DATE_INVALID', 'The last day cannot be before the first.'],
];

type Result = { error: string | null; message?: string };

export async function saveBatch(input: unknown): Promise<Result> {
  const p = batchSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_coaching_batch', {
    p_campus_id: p.data.campusId, p_name: p.data.name, p_subject: p.data.subject, p_teacher_staff_id: p.data.teacherId || null,
    p_monthly_fee_paisa: toPaisa(Number(p.data.feePkr)), p_schedule: p.data.schedule, p_is_active: p.data.isActive, p_id: p.data.id,
  });
  if (error) return { error: mapRpcError(error.message, ERRORS) };
  revalidatePath('/students/coaching');
  return { error: null };
}

export async function enrolInBatch(input: unknown): Promise<Result> {
  const p = coachingEnrolSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: student } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber).is('deleted_at', null).maybeSingle();
  if (!student) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('enrol_coaching_student', { p_batch_id: p.data.batchId, p_student_id: student.id, p_starts_on: p.data.startsOn });
  if (error) return { error: mapRpcError(error.message, ERRORS) };
  revalidatePath('/students/coaching');
  return { error: null };
}

export async function endEnrolment(id: string): Promise<Result> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'That enrolment no longer exists.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('end_coaching_enrolment', { p_id: id });
  if (error) return { error: mapRpcError(error.message, ERRORS) };
  revalidatePath('/students/coaching');
  return { error: null };
}

export async function postCoachingCharges(input: unknown): Promise<Result> {
  const p = postMonthSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Choose a month.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('post_coaching_charges', { p_month: `${p.data.month}-01` });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the accountant or the Principal can post coaching fees.' };
    return { error: mapRpcError(error.message, ERRORS) };
  }
  revalidatePath('/students/coaching');
  return { error: null, message: data === 0 ? 'Nothing new to post for that month.' : `Posted ${data} coaching fee${data === 1 ? '' : 's'}.` };
}
