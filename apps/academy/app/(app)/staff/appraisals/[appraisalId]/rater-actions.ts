'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { rpcError, type ActionResult } from '@/lib/transport/rpc';

export async function reassignRater(appraisalId: string, values: Record<string, string>): Promise<ActionResult> {
  if (!/^[0-9a-f-]{36}$/i.test(values.raterId ?? '')) return { error: 'Choose the new rater.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('reassign_appraisal_rater', { p_appraisal_id: appraisalId, p_rater_id: values.raterId! });
  if (error) return { error: rpcError(error.message, { RATER_NOT_FOUND: 'That person is not an active user of this school.', APPRAISAL_NOT_EDITABLE: 'Only an appraisal still being prepared can change its rater.' }) };
  revalidatePath(`/staff/appraisals/${appraisalId}`);
  return { error: null, message: 'Rater changed.' };
}
