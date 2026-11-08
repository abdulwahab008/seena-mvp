'use server';

import { supabaseServer } from '@/lib/supabase/server';
import { registrationSchema } from './schema';

export async function registerSchool(input: unknown): Promise<{ error: string | null }> {
  const p = registrationSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('submit_school_registration', {
    p_school_name: p.data.schoolName,
    p_contact_name: p.data.contactName,
    p_phone: p.data.phone,
    p_email: p.data.email || undefined,
    p_city: p.data.city || undefined,
    p_students: p.data.students ? Number(p.data.students) : undefined,
    p_message: p.data.message || undefined,
  });
  if (error) {
    if (error.message.includes('TOO_MANY_REQUESTS')) return { error: 'We already have your request from this number. We will call you soon.' };
    return { error: 'Could not send your request. Check the details and try again.' };
  }
  return { error: null };
}
