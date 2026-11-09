'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { replySchema, threadSchema } from './schema';

const message = (error: { message: string }) =>
  error.message.includes('FORBIDDEN') ? 'Only staff can post here.' : error.message.includes('THREAD_NOT_FOUND') ? 'That thread no longer exists.' : 'Something went wrong. Try again.';

export async function postThread(input: unknown): Promise<{ error: string | null; id?: string }> {
  const p = threadSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the post.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('post_discussion_thread', { p_title: p.data.title, p_body: p.data.body });
  if (error) return { error: message(error) };
  revalidatePath('/communication/discussions');
  return { error: null, id: data };
}

export async function postReply(input: unknown): Promise<{ error: string | null }> {
  const p = replySchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the reply.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('post_discussion_reply', { p_thread_id: p.data.threadId, p_body: p.data.body });
  if (error) return { error: message(error) };
  revalidatePath(`/communication/discussions/${p.data.threadId}`);
  revalidatePath('/communication/discussions');
  return { error: null };
}
