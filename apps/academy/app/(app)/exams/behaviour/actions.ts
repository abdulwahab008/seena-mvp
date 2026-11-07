'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';

export async function addStandardTraits(): Promise<{ error: string | null }> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('ensure_behaviour_traits');
  if (error) return { error: 'Only teaching staff can set up behaviour traits.' };
  revalidatePath('/exams/behaviour');
  return { error: null };
}

const ratingsSchema = z.object({
  termId: z.string().uuid(),
  ratings: z.array(z.object({ enrolmentId: z.string().uuid(), traitId: z.string().uuid(), rating: z.enum(['', 'A', 'B', 'C', 'D', 'E']) })),
});

export async function saveRatings(input: unknown): Promise<{ error: string | null }> {
  const p = ratingsSchema.safeParse(input);
  if (!p.success) return { error: 'Ratings are A to E.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('save_behaviour_ratings', {
    p_exam_term_id: p.data.termId,
    p_ratings: p.data.ratings.map((r) => ({ enrolment_id: r.enrolmentId, trait_id: r.traitId, rating: r.rating })),
  });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You cannot rate students on this campus.' : 'Something went wrong. Try again.' };
  revalidatePath('/exams/behaviour');
  return { error: null };
}
