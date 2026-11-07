'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

const schema = z.object({ keepGr: z.string().trim().min(1, 'Enter the GR number to keep'), removeGr: z.string().trim().min(1, 'Enter the duplicate GR number') });

type Pair = { keep: { id: string; name: string; gr: string }; remove: { id: string; name: string; gr: string } };

async function resolve(input: unknown): Promise<{ error: string } | Pair> {
  const p = schema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the GR numbers.' };
  if (p.data.keepGr === p.data.removeGr) return { error: 'Enter two different GR numbers.' };
  const supabase = await supabaseServer();
  const { data } = await supabase.from('student').select('id, name_en, gr_number').in('gr_number', [p.data.keepGr, p.data.removeGr]).is('deleted_at', null);
  const keep = data?.find((s) => s.gr_number === p.data.keepGr);
  const remove = data?.find((s) => s.gr_number === p.data.removeGr);
  if (!keep || !remove) return { error: 'Both GR numbers must belong to students in the school.' };
  return { keep: { id: keep.id, name: keep.name_en, gr: keep.gr_number }, remove: { id: remove.id, name: remove.name_en, gr: remove.gr_number } };
}

function message(m: string, detail?: string) {
  if (m.includes('FORBIDDEN')) return 'Only the owner or a principal can merge students.';
  if (m.includes('MERGE_CONFLICT')) return `Both records have ${detail ?? 'an entry'} that can exist only once (for example, an enrolment in the same session). Remove one first.`;
  if (m.includes('MERGE_BLOCKED')) return `A sealed record stops the merge: ${detail ?? ''}`;
  return 'Something went wrong. Try again.';
}

export async function previewMerge(input: unknown): Promise<{ error: string | null; pair?: Pair; moves?: { table: string; rows: number }[] }> {
  const r = await resolve(input);
  if ('error' in r) return { error: r.error };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('preview_student_merge', { p_keep_id: r.keep.id, p_remove_id: r.remove.id });
  if (error) return { error: message(error.message, error.details) };
  return { error: null, pair: r, moves: (data ?? []).map((m) => ({ table: m.table_name.replaceAll('_', ' '), rows: Number(m.row_count) })) };
}

export async function mergeStudents(input: unknown): Promise<{ error: string | null }> {
  const r = await resolve(input);
  if ('error' in r) return { error: r.error };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('merge_students', { p_keep_id: r.keep.id, p_remove_id: r.remove.id });
  if (error) return { error: message(error.message, error.details) };
  revalidatePath('/students');
  return { error: null };
}
