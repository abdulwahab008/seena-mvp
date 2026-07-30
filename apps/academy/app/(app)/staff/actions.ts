'use server';

import { z } from 'zod';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';

const InviteSchema = z.object({
  email: z.string().email('Must be a valid email address'),
  role: z.enum([
    'principal', 'vice_principal', 'admissions_officer', 'accountant', 'exam_controller',
    'head_of_department', 'class_teacher', 'subject_teacher', 'hr_manager', 'librarian',
    'transport_manager', 'receptionist',
  ]),
});

export type InviteState = { error: string | null };

export async function inviteStaff(campusId: string, _prev: InviteState, formData: FormData): Promise<InviteState> {
  const parsed = InviteSchema.safeParse({ email: formData.get('email'), role: formData.get('role') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('invite_user', {
    p_email: parsed.data.email,
    p_role: parsed.data.role,
    p_campus_ids: [campusId],
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to invite staff.' };
    return { error: 'Could not send invitation.' };
  }

  revalidatePath('/staff');
  return { error: null };
}
