'use server';

import { revalidatePath } from 'next/cache';
import { setSiblingDiscountSchemeSchema, detectSiblingGroupsSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

export async function setSiblingDiscountScheme(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = setSiblingDiscountSchemeSchema.safeParse({
    siblingRank: formData.get('siblingRank'),
    schemeId: formData.get('schemeId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_sibling_discount_scheme', {
    p_sibling_rank: parsed.data.siblingRank,
    p_scheme_id: parsed.data.schemeId,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to configure sibling discount ranks.' };
    if (error.message.includes('CONCESSION_SCHEME_NOT_FOUND')) return { error: 'Scheme not found.' };
    return { error: 'Could not save the rank mapping.' };
  }

  revalidatePath('/fees/sibling-discounts');
  return { error: null };
}

export type ScanState = {
  error: string | null;
  groupsFound?: number;
  proposalsCreated?: number;
  needsReview?: { enrolment_id: string; current_rank: number; existing_award_id: string }[];
};

type DetectSiblingGroupsResponse = {
  groups_found: number;
  proposals_created: number;
  needs_review: { enrolment_id: string; current_rank: number; existing_award_id: string }[];
};

export async function detectSiblingGroups(_prev: ScanState, formData: FormData): Promise<ScanState> {
  const parsed = detectSiblingGroupsSchema.safeParse({
    campusId: formData.get('campusId'),
    sessionId: formData.get('sessionId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('detect_sibling_groups', {
    p_campus_id: parsed.data.campusId,
    p_session_id: parsed.data.sessionId,
  });
  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to run the sibling detection scan.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    return { error: 'Could not run the scan.' };
  }

  revalidatePath('/fees/sibling-discounts');
  const result = data as DetectSiblingGroupsResponse;
  return {
    error: null,
    groupsFound: result.groups_found,
    proposalsCreated: result.proposals_created,
    needsReview: result.needs_review,
  };
}
