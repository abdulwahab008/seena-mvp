'use server';

import { randomUUID } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer } from '@/lib/supabase/server';
import { libraryTitleSchema, type LibraryTitleInput } from '@/lib/validation';
import { libraryErrorMessage } from '@/lib/library';

type Result = { error: string | null };

const COVER_MAX_BYTES = 5 * 1024 * 1024;
const COVER_TYPES: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };

export async function saveTitle(input: LibraryTitleInput, titleId?: string): Promise<Result & { id?: string }> {
  const p = libraryTitleSchema.safeParse(input);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('save_library_title', {
    p_title: p.data.title,
    p_raw_isbn: p.data.rawIsbn || undefined,
    p_title_ur: p.data.titleUr || undefined,
    p_author: p.data.author || undefined,
    p_publisher: p.data.publisher || undefined,
    p_edition: p.data.edition || undefined,
    p_language: p.data.language,
    p_dewey: p.data.dewey || undefined,
    p_subject_id: p.data.subjectId || undefined,
    p_id: titleId,
  });
  if (error) return { error: libraryErrorMessage(error.message) };
  revalidatePath('/library/titles');
  return { error: null, id: data as string };
}

export async function uploadCover(titleId: string, formData: FormData): Promise<Result> {
  if (!z.string().uuid().safeParse(titleId).success) return { error: 'Invalid title.' };
  const file = formData.get('cover');
  if (!(file instanceof File) || file.size === 0) return { error: 'Choose an image.' };
  const ext = COVER_TYPES[file.type];
  if (!ext) return { error: 'Only JPEG, PNG or WebP images are accepted.' };
  if (file.size > COVER_MAX_BYTES) return { error: 'The cover image must be at most 5 MB.' };

  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  const { data: me } = await supabase.from('app_user').select('tenant_id').eq('user_id', user!.id).maybeSingle();
  if (!me) return { error: 'You do not have permission to do this.' };

  const path = `${me.tenant_id}/${titleId}/${randomUUID()}.${ext}`;
  const { error: uploadError } = await supabase.storage.from('library-covers').upload(path, file, { contentType: file.type, upsert: false });
  if (uploadError) return { error: 'The cover could not be uploaded. Please try again.' };
  const { error } = await supabase.rpc('set_library_title_cover', { p_title_id: titleId, p_cover_path: path });
  if (error) {
    await supabase.storage.from('library-covers').remove([path]);
    return { error: libraryErrorMessage(error.message) };
  }
  revalidatePath('/library/titles');
  return { error: null };
}
