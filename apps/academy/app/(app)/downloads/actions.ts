'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

const ALLOWED = new Set([
  'application/pdf', 'image/jpeg', 'image/png', 'image/webp', 'text/plain',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
]);
const MAX_BYTES = 10 * 1024 * 1024;

const metaSchema = z.object({
  campusId: z.string().uuid(),
  category: z.enum(['syllabus', 'material', 'other']),
  title: z.string().trim().min(1, 'Enter a title').max(200),
  classLevelId: z.string().uuid().optional().or(z.literal('')),
  sectionId: z.string().uuid().optional().or(z.literal('')),
});

export async function uploadDownload(formData: FormData): Promise<{ error: string | null }> {
  const meta = metaSchema.safeParse(Object.fromEntries(['campusId', 'category', 'title', 'classLevelId', 'sectionId'].map((k) => [k, formData.get(k) ?? undefined])));
  if (!meta.success) return { error: meta.error.issues[0]?.message ?? 'Check the form.' };
  const file = formData.get('file');
  if (!(file instanceof File) || file.size === 0) return { error: 'Choose a file.' };
  if (file.size > MAX_BYTES) return { error: 'Files can be at most 10 MB.' };
  if (!ALLOWED.has(file.type)) return { error: 'Only PDF, Word, Excel, PowerPoint, text and image files can be shared.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('register_download_item', {
    p_campus_id: meta.data.campusId,
    p_category: meta.data.category,
    p_title: meta.data.title,
    p_class_level_id: meta.data.classLevelId || null,
    p_section_id: meta.data.sectionId || null,
    p_filename: file.name.slice(0, 200),
    p_mime_type: file.type,
    p_size_bytes: file.size,
  });
  if (error) return { error: error.message.includes('FORBIDDEN') ? 'You cannot share files on this campus.' : 'Could not save the file.' };

  const { id, storage_path } = data as { id: string; storage_path: string };
  const admin = supabaseServiceRole();
  const { error: uploadError } = await admin.storage.from('downloads').upload(storage_path, file, { contentType: file.type, upsert: false });
  if (uploadError) {
    await admin.from('download_item').delete().eq('id', id);
    return { error: 'The file could not be uploaded. Try again.' };
  }
  revalidatePath('/downloads');
  return { error: null };
}

export async function deleteDownload(id: string): Promise<{ error: string | null }> {
  if (!z.string().uuid().safeParse(id).success) return { error: 'Invalid file.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_download_item', { p_id: id });
  if (error) return { error: 'You can only remove files you shared.' };
  revalidatePath('/downloads');
  return { error: null };
}
