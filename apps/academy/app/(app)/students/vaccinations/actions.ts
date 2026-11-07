'use server';

import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase/server';
import { vaccinationSchema } from './schema';

export async function saveVaccination(input: unknown): Promise<{ error: string | null }> {
  const p = vaccinationSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Check the form.' };
  const supabase = await supabaseServer();
  const { data: student } = await supabase.from('student').select('id').eq('gr_number', p.data.grNumber).is('deleted_at', null).maybeSingle();
  if (!student) return { error: 'No student has that GR number.' };
  const { error } = await supabase.rpc('save_student_vaccination', {
    p_student_id: student.id, p_vaccine: p.data.vaccine, p_dose_no: Number(p.data.doseNo),
    p_due_on: p.data.dueOn || undefined, p_given_on: p.data.givenOn || undefined, p_notes: p.data.notes,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'Only the nurse or Principal can record vaccinations.' };
    if (error.message.includes('DATE_INVALID')) return { error: 'A dose cannot be given in the future.' };
    return { error: 'Something went wrong. Try again.' };
  }
  revalidatePath('/students/vaccinations');
  return { error: null };
}
