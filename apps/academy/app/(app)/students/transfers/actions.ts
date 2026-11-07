'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'You cannot do this for that campus.';
  if (m.includes('ENROLMENT_NOT_FOUND')) return 'That student has no active enrolment.';
  if (m.includes('SAME_CAMPUS')) return 'That section is on the same campus; change the section instead.';
  if (m.includes('SECTION_NOT_FOUND')) return 'Choose an active section in the same session at the other campus.';
  if (m.includes('uq_campus_transfer_open')) return 'This student already has a transfer waiting.';
  if (m.includes('TRANSFER_DECIDED')) return 'This transfer is already decided.';
  return 'Something went wrong. Try again.';
}

const requestSchema = z.object({ grNumber: z.string().trim().min(1, 'Enter the GR number'), sectionId: z.string().uuid('Choose a section'), reason: z.string().trim().min(1, 'Give a reason').max(500) });

export async function requestTransfer(input: unknown): Promise<{ error: string | null }> {
  const p = requestSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: student } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber).is('deleted_at', null).maybeSingle();
  if (!student) return { error: 'No student has that GR number.' };
  const { data: enrolment } = await supabase.from('enrolment').select('id').eq('student_id', student.id).eq('status', 'active').maybeSingle();
  if (!enrolment) return { error: 'That student has no active enrolment.' };
  const { error } = await supabase.rpc('request_campus_transfer', { p_enrolment_id: enrolment.id, p_to_section_id: p.data.sectionId, p_reason: p.data.reason });
  if (error) return { error: message(error.message) };
  revalidatePath('/students/transfers');
  return { error: null };
}

export async function decideTransfer(id: string, approve: boolean, note: string): Promise<{ error: string | null }> {
  const p = z.object({ id: z.string().uuid(), note: z.string().trim().max(500) }).safeParse({ id, note });
  if (!p.success) return { error: 'Check the note.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('decide_campus_transfer', { p_id: p.data.id, p_approve: approve, p_note: p.data.note });
  if (error) return { error: message(error.message) };
  revalidatePath('/students/transfers');
  return { error: null };
}
