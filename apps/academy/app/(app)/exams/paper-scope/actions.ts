'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { nudgeWorker } from '@/lib/worker-nudge';
import { paperScopeRequestSchema, type PaperRequestInput } from '@/lib/validation';

type Result = { error: string | null; id?: string };

function mapError(message: string): string {
  // The database words the untaught-chapter refusal exactly as the user should read it.
  if (message.includes('has not been taught yet')) return message;
  if (message.includes('OVERRIDE_REQUIRES_EXAM_CONTROLLER')) return 'Only an Exam Controller can include untaught chapters.';
  if (message.includes('UNITS_MUST_SHARE_ONE_SYLLABUS')) return 'Choose chapters of one class and subject.';
  if (message.includes('FORBIDDEN')) return 'You are not allowed to request papers for this campus.';
  return 'Something went wrong. Please try again.';
}

export async function requestPaper(input: PaperRequestInput): Promise<Result> {
  const p = paperScopeRequestSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('submit_exam_paper_request', {
    p_unit_ids: p.data.unitIds,
    p_title: p.data.title,
    p_section_id: p.data.sectionId || undefined,
    p_untaught_override: p.data.untaughtOverride ?? false,
  });
  if (error) return { error: mapError(error.message) };
  await nudgeWorker('/api/internal/exam-papers/run');
  revalidatePath('/exams/paper-scope');
  return { error: null, id: data as string };
}
