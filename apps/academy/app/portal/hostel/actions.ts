'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { messOffSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  MESS_OFF_OVERLAP: 'You already have a request covering some of these days.',
  NOTICE_PERIOD_NOT_MET: 'It is too late to request these days. Please ask earlier next time, or contact the hostel (NOTICE_PERIOD_NOT_MET).',
  NOT_A_BOARDER: 'This child does not hold a hostel bed on those dates.',
  SPAN_INVALID: 'Check the dates (at most 120 days).',
  FORBIDDEN: 'You cannot make this request.',
};

export async function requestMessOff(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(messOffSchema, values);
  if (!p.ok) return { error: p.error };
  if (!p.data.studentId) return { error: 'Choose your child.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('request_mess_off', { p_student_id: p.data.studentId, p_from: p.data.from, p_to: p.data.to, p_reason: p.data.reason });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/portal/hostel');
  return { error: null, message: 'Request sent.' };
}
