'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { coverageSchema, type CoverageInput } from '@/lib/validation';

type Result = { error: string | null };

function mapError(message: string): string {
  if (message.includes('Completion date cannot precede start date')) return 'Completion date cannot precede start date';
  if (message.includes('FORBIDDEN')) return 'You are not assigned to this section and subject.';
  if (message.includes('UNIT_NOT_IN_SYLLABUS')) return 'That chapter is not in this class and subject\'s syllabus.';
  return 'Something went wrong. Please try again.';
}

export async function saveCoverage(input: CoverageInput): Promise<Result> {
  const p = coverageSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_syllabus_coverage', {
    p_section_id: p.data.sectionId,
    p_subject_id: p.data.subjectId,
    p_unit_id: p.data.unitId,
    p_status: p.data.status,
    p_started_on: p.data.startedOn || undefined,
    p_completed_on: p.data.completedOn || undefined,
    p_periods_used: p.data.periodsUsed,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/syllabus-coverage');
  return { error: null };
}
