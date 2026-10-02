'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { guardianClaimSchema } from '@/lib/validation';

const siblingSchema = guardianClaimSchema.pick({ grNumber: true, cnicLast6: true });
export type LinkChildInput = z.input<typeof siblingSchema>;
const resultSchema = z.object({ status: z.enum(['linked', 'not_found', 'locked']) });

export type LinkChildState = { error: string | null; linked: boolean };

export async function linkAnotherChild(input: LinkChildInput): Promise<LinkChildState> {
  const parsed = siblingSchema.safeParse(input);
  if (!parsed.success) return { error: 'We could not match those details. Check them and try again.', linked: false };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('claim_additional_student', {
    p_gr_no: parsed.data.grNumber,
    p_cnic_last6: parsed.data.cnicLast6,
  });
  const result = resultSchema.safeParse(data);
  if (error || !result.success) return { error: 'Something went wrong. Please try again.', linked: false };

  if (result.data.status === 'locked') return { error: 'Too many attempts. Try again in 30 minutes.', linked: false };
  if (result.data.status === 'not_found') return { error: 'We could not match those details. Check them and try again.', linked: false };

  revalidatePath('/portal', 'layout');
  return { error: null, linked: true };
}
