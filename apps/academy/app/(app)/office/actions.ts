'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { contactSchema, taskSchema } from './schema';

type Result = { error: string | null };
const done = (error: { message: string } | null): Result => {
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You cannot do that.' : 'Something went wrong. Try again.' };
  revalidatePath('/office');
  return { error: null };
};

export async function addTask(input: unknown): Promise<Result> {
  const p = taskSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the task.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('add_team_task', { p_title: p.data.title, p_assigned_to: p.data.assignedTo || undefined, p_due_on: p.data.dueOn || undefined });
  return done(error);
}

export async function completeTask(id: string): Promise<Result> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid task.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('complete_team_task', { p_id: id });
  return done(error);
}

export async function addContact(input: unknown): Promise<Result> {
  const p = contactSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the contact.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_office_contact', {
    p_name: p.data.name, p_organisation: p.data.organisation, p_category: p.data.category, p_phone: p.data.phone, p_email: p.data.email,
  });
  if (error?.message.includes('FORBIDDEN')) return { error: 'Only the front office, leadership, HR or the accountant can add contacts.' };
  return done(error);
}
