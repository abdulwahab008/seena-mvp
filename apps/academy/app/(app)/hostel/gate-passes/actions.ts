'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { cancelGatePassSchema, issueGatePassSchema } from '@/lib/validation';
import { karachiLocalToIso } from '@/lib/hostel/gate-pass';
import { loose, parseValues, rpcError, type ActionResult } from '@/lib/transport/rpc';

const MESSAGES = {
  PASS_ALREADY_OPEN: 'This student already has a pass out (PASS_ALREADY_OPEN).',
  NOT_A_BOARDER: 'This student has no hostel stay on that date.',
  GUARDIAN_NOT_VERIFIED: 'The collector\'s CNIC matches no guardian of this student. Only a Principal can release a student to them, with a reason (GUARDIAN_NOT_VERIFIED).',
  OVERRIDE_REASON_REQUIRED: 'Type the reason for releasing the student to someone who is not a recorded guardian.',
  CNIC_INVALID: 'CNIC must be 13 digits.',
  SPAN_INVALID: 'The return time must be after the departure.',
  GATE_PASS_CLOSED: 'This pass is already closed.',
  PASS_NOT_FOUND: 'That pass was not found.',
  REASON_REQUIRED: 'Give a reason.',
  STUDENT_NOT_FOUND: 'No student has that GR number.',
};

export async function issuePass(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(issueGatePassSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { data: s } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber).is('deleted_at', null).maybeSingle();
  if (!s) return { error: MESSAGES.STUDENT_NOT_FOUND };
  const { error } = await supabase.rpc('issue_gate_pass', {
    p_student_id: (s as { id: string }).id, p_purpose: p.data.purpose, p_departs_at: karachiLocalToIso(p.data.departsAt),
    p_expected_back_at: karachiLocalToIso(p.data.expectedBackAt), p_collector_name: p.data.collectorName, p_collector_cnic: p.data.collectorCnic,
    p_destination: p.data.destination, p_override_reason: p.data.overrideReason,
  });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/gate-passes');
  return { error: null, message: 'Gate pass issued.' };
}

export async function returnPass(passId: string): Promise<ActionResult> {
  if (!z.string().uuid().safeParse(passId).success) return { error: 'Invalid pass.' };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('close_gate_pass', { p_pass_id: passId });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/gate-passes');
  return { error: null, message: 'Return recorded.' };
}

export async function cancelPass(values: Record<string, string>): Promise<ActionResult> {
  const p = parseValues(cancelGatePassSchema, values);
  if (!p.ok) return { error: p.error };
  const supabase = loose(await supabaseServer());
  const { error } = await supabase.rpc('cancel_gate_pass', { p_pass_id: p.data.passId, p_reason: p.data.reason });
  if (error) return { error: rpcError(error.message, MESSAGES) };
  revalidatePath('/hostel/gate-passes');
  return { error: null, message: 'Pass cancelled.' };
}
