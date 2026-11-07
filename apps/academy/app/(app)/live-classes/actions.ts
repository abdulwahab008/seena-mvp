'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'You cannot schedule or cancel classes for that section.';
  if (m.includes('live_class_meeting_url_check')) return 'The meeting link must start with https://';
  if (m.includes('live_class_duration_min_check')) return 'A class lasts 5 to 240 minutes.';
  return 'Something went wrong. Try again.';
}

const schema = z.object({
  sectionId: z.string().uuid('Choose a section'),
  subjectId: z.string().uuid().or(z.literal('')),
  title: z.string().trim().min(1, 'Enter a title').max(150),
  startsAt: z.string().datetime({ offset: true }),
  durationMin: z.coerce.number().int().min(5).max(240),
  meetingUrl: z.string().trim().url('Paste the meeting link').startsWith('https://', 'The link must start with https://'),
});

export async function scheduleLiveClass(input: unknown): Promise<{ error: string | null }> {
  const p = schema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('schedule_live_class', {
    p_section_id: p.data.sectionId, p_subject_id: p.data.subjectId || undefined, p_title: p.data.title,
    p_starts_at: p.data.startsAt, p_duration_min: p.data.durationMin, p_meeting_url: p.data.meetingUrl,
  });
  if (error) return { error: message(error.message) };
  revalidatePath('/live-classes');
  return { error: null };
}

export async function cancelLiveClass(id: string): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid class.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('cancel_live_class', { p_id: id });
  if (error) return { error: message(error.message) };
  revalidatePath('/live-classes');
  return { error: null };
}
