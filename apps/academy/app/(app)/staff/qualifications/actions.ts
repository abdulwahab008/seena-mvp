'use server';

import { revalidatePath } from 'next/cache';
import { addStaffQualificationSchema, verifyStaffQualificationSchema } from '@/lib/validation';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

export type ActionState = { error: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  if (message.includes('STAFF_NOT_FOUND')) return 'Staff member not found.';
  if (message.includes('QUALIFICATION_NOT_FOUND')) return 'Qualification not found.';
  if (message.includes('chk_qualification_year_reasonable')) return 'Year completed is out of a reasonable range.';
  return 'Something went wrong.';
}

export async function addStaffQualification(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = addStaffQualificationSchema.safeParse({
    staffId: formData.get('staffId'),
    level: formData.get('level'),
    discipline: formData.get('discipline'),
    institution: formData.get('institution'),
    yearCompleted: formData.get('yearCompleted'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const file = formData.get('document');
  let documentId: string | null = null;

  if (file && file instanceof File && file.size > 0) {
    const ALLOWED_MIME_TYPES = ['image/jpeg', 'image/png', 'application/pdf'];
    if (!ALLOWED_MIME_TYPES.includes(file.type)) {
      return { error: 'Only PDF, JPEG, and PNG files are accepted.' };
    }
    if (file.size > 10 * 1024 * 1024) {
      return { error: 'Document must be less than 10 MB.' };
    }

    const ext = file.name.includes('.') ? file.name.split('.').pop()!.toLowerCase() : 'pdf';
    const storagePath = `${parsed.data.staffId}/${crypto.randomUUID()}.${ext}`;

    const admin = supabaseServiceRole();
    const { error: uploadError } = await admin.storage
      .from('staff-docs')
      .upload(storagePath, file, { contentType: file.type, upsert: false });

    if (uploadError) {
      return { error: 'Failed to upload document file. Please try again.' };
    }

    const label = `${parsed.data.level.toUpperCase()} - ${parsed.data.discipline}`;
    const { data: createdDocId, error: docError } = await supabase.rpc('add_staff_document', {
      p_staff_id: parsed.data.staffId,
      p_label: label,
      p_storage_path: storagePath,
    });

    if (docError || !createdDocId) {
      await admin.storage.from('staff-docs').remove([storagePath]);
      return { error: docError ? mapError(docError.message) : 'Failed to record staff document.' };
    }

    documentId = createdDocId as string;
  }

  const { error } = await supabase.rpc('add_staff_qualification', {
    p_staff_id: parsed.data.staffId,
    p_level: parsed.data.level,
    p_discipline: parsed.data.discipline,
    p_institution: parsed.data.institution,
    p_year_completed: parsed.data.yearCompleted,
    p_document_id: documentId ?? undefined,
  });

  if (error) {
    if (documentId) {
      await supabase.rpc('delete_staff_document', { p_document_id: documentId });
    }
    return { error: mapError(error.message) };
  }

  revalidatePath('/staff/qualifications');
  return { error: null };
}

export async function verifyStaffQualification(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = verifyStaffQualificationSchema.safeParse({
    qualificationId: formData.get('qualificationId'),
    status: formData.get('status'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('verify_staff_qualification', {
    p_qualification_id: parsed.data.qualificationId,
    p_status: parsed.data.status,
  });
  if (error) return { error: mapError(error.message) };

  revalidatePath('/staff/qualifications');
  return { error: null };
}

export async function getStaffDocumentSignedUrl(
  documentId: string
): Promise<{ error: string | null; url: string | null; filename?: string; mimeType?: string }> {
  const supabase = await supabaseServer();
  const { data: doc, error: fetchError } = await supabase
    .from('staff_document')
    .select('id, label, storage_path')
    .eq('id', documentId)
    .single();

  if (fetchError || !doc || !doc.storage_path) {
    return { error: 'Document not found or has no attached file.', url: null };
  }

  const admin = supabaseServiceRole();
  const { data, error } = await admin.storage.from('staff-docs').createSignedUrl(doc.storage_path, 3600);
  if (error || !data) {
    return { error: 'Could not generate preview link.', url: null };
  }

  const isPdf = doc.storage_path.toLowerCase().endsWith('.pdf');
  const isImage = /\.(jpe?g|png)$/i.test(doc.storage_path);
  const mimeType = isPdf ? 'application/pdf' : isImage ? 'image/jpeg' : 'application/octet-stream';

  return { error: null, url: data.signedUrl, filename: doc.label, mimeType };
}
