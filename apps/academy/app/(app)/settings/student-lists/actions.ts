'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { mapRpcError } from '@/lib/rpc-action';
import { lookupSchema } from './schema';

const ERRORS: [string, string][] = [
  ['FORBIDDEN', 'Only the Principal or an admissions officer can change these lists.'],
  ['LOOKUP_DUPLICATE', 'That name is already on this list.'],
  ['LOOKUP_NOT_FOUND', 'That entry no longer exists.'],
];

export async function saveLookup(input: unknown): Promise<{ error: string | null }> {
  const p = lookupSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_student_lookup', { p_kind: p.data.kind, p_name: p.data.name, p_area: p.data.area || undefined, p_id: p.data.id });
  if (error) return { error: mapRpcError(error.message, ERRORS) };
  revalidatePath('/settings/student-lists');
  return { error: null };
}

export async function setLookupActive(id: string, active: boolean): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'That entry no longer exists.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_student_lookup_active', { p_id: id, p_is_active: active });
  if (error) return { error: mapRpcError(error.message, ERRORS) };
  revalidatePath('/settings/student-lists');
  return { error: null };
}
