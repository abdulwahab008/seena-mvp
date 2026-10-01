'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { messOffSchema, publishMessMenuSchema, saveMessMenuSchema } from '@/lib/validation';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  MENU_INCOMPLETE: 'All 21 meal slots (7 days x 3 meals) must be filled before publishing (MENU_INCOMPLETE).',
  MENU_PUBLISHED: 'This week is already published and cannot be rewritten.',
  MESS_OFF_OVERLAP: 'This student already has a mess-off covering some of those dates.',
  NOTICE_PERIOD_NOT_MET: 'Too late: mess-off must be requested before the notice period (NOTICE_PERIOD_NOT_MET).',
  NOT_A_BOARDER: 'This student does not hold a hostel bed on those dates.',
  SPAN_INVALID: 'Check the dates (at most 120 days).',
  STUDENT_NOT_FOUND: 'No student has that GR number.',
  ALREADY_DECIDED: 'This request was already decided.',
};

export async function saveMenu(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(saveMessMenuSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data, error } = await supabase.rpc('save_mess_menu', { p_campus_id: p.data.campusId, p_week_start: p.data.weekStart, p_slots: p.data.slots });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/mess');
  return { error: null, message: `${data ?? 0} of 21 slots saved.` };
}

export async function publishMenu(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(publishMessMenuSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('publish_mess_menu', { p_campus_id: p.data.campusId, p_week_start: p.data.weekStart });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/mess');
  return { error: null, message: 'Menu published to parents and students.' };
}

export async function recordAway(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(messOffSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data: s } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber ?? '').is('deleted_at', null).maybeSingle();
  if (!s) return { error: MESSAGES.STUDENT_NOT_FOUND };
  const { error } = await supabase.rpc('record_mess_off', { p_student_id: (s as { id: string }).id, p_from: p.data.from, p_to: p.data.to, p_reason: p.data.reason });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/mess');
  return { error: null, message: 'Away period recorded.' };
}

export async function decideAway(id: string, approve: boolean): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid request.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('decide_mess_off', { p_mess_off_id: id, p_approve: approve });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/mess');
  return { error: null, message: approve ? 'Approved.' : 'Rejected.' };
}
