'use server';

import { revalidatePath } from 'next/cache';
import { z } from 'zod';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';
import { sniffMime } from '@/lib/uploads/sniff';

const MAX_FILES = 5;
const MAX_BYTES = 5 * 1024 * 1024;

export type SubmitResult = { error: string | null; done?: { version: number; isLate: boolean; lateByMinutes: number } };

function mapError(message: string): string {
  if (message.includes('SUBMISSION_CHECKED')) return 'This submission has been checked and can no longer be changed';
  if (message.includes('TEXT_TOO_LONG')) return 'Text can be at most 2000 characters';
  if (message.includes('FILE_EXCEEDS_5MB')) return 'File exceeds 5 MB limit';
  if (message.includes('MAX_5_FILES')) return 'Maximum 5 files per submission';
  if (message.includes('EMPTY_SUBMISSION')) return 'Add some text or at least one file';
  if (message.includes('FORBIDDEN') || message.includes('42501')) return 'You cannot submit work for this assignment.';
  return 'Something went wrong. Please try again.';
}

export async function submitHomework(formData: FormData): Promise<SubmitResult> {
  const ids = z.object({ homeworkId: z.string().uuid(), enrolmentId: z.string().uuid(), text: z.string().max(2000, 'Text can be at most 2000 characters').optional() }).safeParse({
    homeworkId: formData.get('homeworkId'),
    enrolmentId: formData.get('enrolmentId'),
    text: (formData.get('text') as string | null) || undefined,
  });
  if (!ids.success) return { error: ids.error.issues[0]?.message ?? 'Invalid input.' };
  const files = formData.getAll('files').filter((f): f is File => f instanceof File && f.size > 0);
  if (files.length > MAX_FILES) return { error: 'Maximum 5 files per submission' };

  const prepared: { file: File; bytes: Uint8Array; mime: NonNullable<ReturnType<typeof sniffMime>> }[] = [];
  for (const file of files) {
    if (file.size > MAX_BYTES) return { error: `${file.name}: File exceeds 5 MB limit` };
    const bytes = new Uint8Array(await file.arrayBuffer());
    const mime = sniffMime(bytes);
    if (!mime) return { error: `${file.name}: only PDF, JPEG, PNG or WebP files can be submitted` };
    prepared.push({ file, bytes, mime });
  }

  const supabase = await supabaseServer();
  const { data: submissionId, error: beginError } = await supabase.rpc('begin_submission', { p_homework_id: ids.data.homeworkId, p_enrolment_id: ids.data.enrolmentId, p_text: ids.data.text });
  if (beginError || !submissionId) return { error: mapError(beginError?.message ?? '') };

  const service = supabaseServiceRole();
  for (const p of prepared) {
    const { data, error } = await supabase.rpc('add_submission_file', { p_submission_id: submissionId, p_filename: p.file.name, p_mime_type: p.mime, p_size_bytes: p.file.size });
    if (error) return { error: mapError(error.message) };
    const meta = z.object({ file_id: z.string().uuid(), storage_path: z.string() }).parse(data);
    const { error: uploadError } = await service.storage.from('homework-submissions').upload(meta.storage_path, p.bytes, { contentType: p.mime });
    if (uploadError) {
      await supabase.rpc('remove_submission_file', { p_file_id: meta.file_id });
      return { error: 'A file could not be uploaded. Nothing was submitted; please try again.' };
    }
  }

  const { data: result, error: finalizeError } = await supabase.rpc('finalize_submission', { p_submission_id: submissionId });
  if (finalizeError) return { error: mapError(finalizeError.message) };
  const r = z.object({ version: z.number(), is_late: z.boolean(), late_by_minutes: z.number() }).parse(result);
  revalidatePath('/portal/homework/submit');
  return { error: null, done: { version: r.version, isLate: r.is_late, lateByMinutes: r.late_by_minutes } };
}
