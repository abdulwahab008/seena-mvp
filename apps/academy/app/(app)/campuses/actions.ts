'use server';

import { revalidatePath } from 'next/cache';
import { createCampusSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type CreateCampusState = { error: string | null };

// FR-A02: create an additional campus under the caller's own tenant.
// Authorization (owner/super_admin, tenant match) is enforced inside
// create_campus() itself — this action just shapes the client-facing error.
export async function createCampus(
  _prev: CreateCampusState,
  formData: FormData,
): Promise<CreateCampusState> {
  const parsed = createCampusSchema.safeParse({
    code: formData.get('code'),
    name: formData.get('name'),
    city: formData.get('city') || undefined,
  });
  if (!parsed.success) {
    return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  }

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('create_campus', {
    p_code: parsed.data.code,
    p_name: parsed.data.name,
    p_city: parsed.data.city,
  });

  if (error) {
    if (error.message.includes('CAMPUS_CODE_TAKEN')) return { error: `Campus code "${parsed.data.code}" is already in use.` };
    if (error.message.includes('CAMPUS_LIMIT_REACHED')) return { error: 'This tenant already has the maximum of 50 campuses.' };
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to create a campus.' };
    return { error: 'Could not create campus.' };
  }

  revalidatePath('/campuses');
  return { error: null };
}

export type ArchiveCampusState = { error: string | null };

export async function archiveCampus(campusId: string): Promise<ArchiveCampusState> {
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('archive_campus', { p_campus_id: campusId });

  if (error) {
    if (error.message.includes('FORBIDDEN')) return { error: 'You do not have permission to archive this campus.' };
    if (error.message.includes('CAMPUS_NOT_FOUND')) return { error: 'Campus not found.' };
    return { error: 'Could not archive campus.' };
  }

  revalidatePath('/campuses');
  return { error: null };
}
