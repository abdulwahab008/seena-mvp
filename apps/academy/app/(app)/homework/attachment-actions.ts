'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { sniffMime } from '@/lib/uploads/sniff';
import { nudgeWorker } from '@/lib/worker-nudge';

const MAX_BYTES = 5 * 1024 * 1024;

export type AttachResult = { error: string | null };

function mapError(message: string): string {
  if (message.includes('FILE_EXCEEDS_5MB')) return 'File exceeds 5 MB limit';
  if (message.includes('MAX_5_ATTACHMENTS')) return 'Maximum 5 attachments per assignment';
  if (message.includes('ATTACHMENT_TYPE_NOT_ALLOWED')) return 'Only PDF, JPEG, PNG or WebP files can be attached';
  if (message.includes('FORBIDDEN')) return 'You cannot change attachments on this assignment.';
  return 'Could not attach the file. Please try again.';
}

export async function uploadHomeworkAttachment(formData: FormData): Promise<AttachResult> {
  const homeworkId = z.string().uuid().safeParse(formData.get('homeworkId'));
  const file = formData.get('file');
  if (!homeworkId.success || !(file instanceof File) || file.size === 0) return { error: 'Choose a file.' };
  if (file.size > MAX_BYTES) return { error: 'File exceeds 5 MB limit' };

  const bytes = new Uint8Array(await file.arrayBuffer());
  const mime = sniffMime(bytes);
  if (!mime) return { error: 'Only PDF, JPEG, PNG or WebP files can be attached' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('register_homework_attachment', { p_homework_id: homeworkId.data, p_filename: file.name, p_mime_type: mime, p_size_bytes: file.size });
  if (error) return { error: mapError(error.message) };
  const meta = z.object({ attachment_id: z.string().uuid(), storage_path: z.string() }).parse(data);

  const { error: uploadError } = await supabaseServiceRole().storage.from('homework-attachments').upload(meta.storage_path, bytes, { contentType: mime });
  if (uploadError) {
    await supabase.rpc('remove_homework_attachment', { p_attachment_id: meta.attachment_id });
    return { error: 'Could not upload the file. Please try again.' };
  }
  revalidatePath('/homework');
  return { error: null };
}

export async function removeHomeworkAttachment(attachmentId: string): Promise<AttachResult> {
  if (!z.string().uuid().safeParse(attachmentId).success) return { error: 'Invalid attachment.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('remove_homework_attachment', { p_attachment_id: attachmentId });
  if (error) return { error: mapError(error.message) };
  await nudgeWorker('/api/internal/storage/purge');
  revalidatePath('/homework');
  return { error: null };
}

export async function deleteHomework(homeworkId: string): Promise<AttachResult> {
  if (!z.string().uuid().safeParse(homeworkId).success) return { error: 'Invalid assignment.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('delete_homework', { p_homework_id: homeworkId });
  if (error) return { error: mapError(error.message) };
  await nudgeWorker('/api/internal/storage/purge');
  revalidatePath('/homework');
  return { error: null };
}
