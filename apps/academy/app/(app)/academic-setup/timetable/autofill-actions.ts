'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

function message(m: string) {
  if (m.includes('FORBIDDEN')) return 'Only the Principal or owner can build the timetable.';
  if (m.includes('VERSION_IMMUTABLE')) return 'Only a draft timetable can be changed.';
  if (m.includes('NO_BELL_TEMPLATE')) return 'Set a default bell template for this campus and shift first.';
  if (m.includes('SAME_SECTION')) return 'Choose a different section to copy from.';
  return 'Something went wrong. Try again.';
}

const ids = z.object({ versionId: z.string().uuid(), sectionId: z.string().uuid() });

export async function autofillSection(versionId: string, sectionId: string): Promise<{ error: string | null; placed?: number; unplaced?: { subject: string; missing: number }[] }> {
  const p = ids.safeParse({ versionId, sectionId });
  if (!p.success) return { error: 'Choose a timetable and section.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('autofill_section_timetable', { p_version_id: versionId, p_section_id: sectionId });
  if (error) return { error: message(error.message) };
  revalidatePath('/academic-setup/timetable');
  const r = data as { placed: number; unplaced: { subject: string; missing: number }[] };
  return { error: null, placed: r.placed, unplaced: r.unplaced };
}

export async function copySection(versionId: string, fromSectionId: string, toSectionId: string): Promise<{ error: string | null; copied?: number; skipped?: number }> {
  const p = ids.extend({ fromSectionId: z.string().uuid('Choose a section to copy from') }).safeParse({ versionId, sectionId: toSectionId, fromSectionId });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Choose a section.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('copy_section_timetable', { p_version_id: versionId, p_from_section_id: fromSectionId, p_to_section_id: toSectionId });
  if (error) return { error: message(error.message) };
  revalidatePath('/academic-setup/timetable');
  const r = data as { copied: number; skipped: number };
  return { error: null, copied: r.copied, skipped: r.skipped };
}
