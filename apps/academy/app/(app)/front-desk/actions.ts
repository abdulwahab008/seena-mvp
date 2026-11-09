'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { FRONT_DESK_KINDS } from './kinds';
import { quickSmsSchema } from './quick-sms-schema';

const opt = (max: number) => z.string().trim().max(max).optional();

const entrySchema = z.object({
  campusId: z.string().uuid(),
  kind: z.enum(FRONT_DESK_KINDS),
  person_name: z.string().trim().min(1, 'Required').max(200),
  phone: opt(30),
  purpose: opt(500),
  host_name: opt(200),
  reference: opt(100),
  details: opt(2000),
  follow_up_on: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional().or(z.literal('')),
});

export async function logEntry(input: z.input<typeof entrySchema>): Promise<{ error: string | null }> {
  const p = entrySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('log_front_desk_entry', {
    p_campus_id: v.campusId,
    p_kind: v.kind,
    p_person_name: v.person_name,
    p_phone: v.phone,
    p_purpose: v.purpose,
    p_host_name: v.host_name,
    p_reference: v.reference,
    p_details: v.details,
    p_follow_up_on: v.follow_up_on || undefined,
  });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You cannot write to this register.' : 'Could not save the entry.' };
  revalidatePath('/front-desk');
  return { error: null };
}

export async function closeEntry(entryId: string): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(entryId).success) return { error: 'Invalid entry.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('close_front_desk_entry', { p_entry_id: entryId });
  if (error) return { error: error.message.includes('ENTRY_NOT_FOUND') ? 'That entry is already closed.' : 'Could not update the entry.' };
  revalidatePath('/front-desk');
  return { error: null };
}

export async function sendQuickSms(input: unknown): Promise<{ error: string | null; queued?: number; skipped?: number }> {
  const p = quickSmsSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the message.' };
  const v = p.data;
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('queue_quick_sms', {
    p_campus_id: v.campusId,
    p_audience: v.audience,
    p_section_id: v.audience === 'section' ? v.sectionId : null,
    p_numbers: v.audience === 'numbers' ? v.numbers.split(/[\s,;]+/).filter(Boolean) : null,
    p_body: v.body,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You cannot send messages from this campus.' };
    if (error.message.includes('NUMBERS_INVALID')) return { error: 'Enter between 1 and 100 numbers.' };
    if (error.message.includes('SECTION_NOT_FOUND')) return { error: 'Choose a class and section.' };
    return { error: 'Could not queue the message.' };
  }
  const result = data as { queued: number; skipped: number };
  revalidatePath('/communication/outbox');
  return { error: null, queued: result.queued, skipped: result.skipped };
}
