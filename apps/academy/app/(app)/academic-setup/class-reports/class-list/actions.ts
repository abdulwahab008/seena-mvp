'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { rpcError, type ActionResult } from '@/lib/transport/rpc';

const PATH = '/academic-setup/class-reports/class-list';

export async function setRollNo(enrolmentId: string, roll: number): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(enrolmentId).success || !Number.isInteger(roll) || roll < 1 || roll > 9999) return { error: 'Enter a roll number from 1.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('fn_set_roll_no', { p_enrolment_id: enrolmentId, p_roll_no: roll });
  if (error) return { error: rpcError(error.message, { uq_roll_no: `Roll ${roll} is already taken in this section.` }) };
  revalidatePath(PATH);
  return { error: null, message: 'Roll number saved.' };
}

export async function renumberAlphabetically(sectionId: string, sessionId: string): Promise<ActionResult> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('fn_resequence_roll_numbers', { p_section_id: sectionId, p_session_id: sessionId });
  if (error) return { error: rpcError(error.message) };
  revalidatePath(PATH);
  return { error: null, message: `Renumbered ${data ?? 0} students A to Z.` };
}
