'use server';

import { revalidatePath } from 'next/cache';
import { complianceDocumentSchema, documentPolicySchema, renewDocumentSchema } from '@/lib/validation';
import { supabaseServer, supabaseServiceRole } from '@/lib/supabase/server';

export type ActionState = { error: string | null; message?: string | null };

function mapError(message: string): string {
  if (message.includes('FORBIDDEN')) return 'Only HR can change compliance documents.';
  if (message.includes('STAFF_NOT_FOUND')) return 'That staff member has no login yet, so a document cannot be filed against them.';
  if (message.includes('DOCUMENT_TYPE_UNKNOWN')) return 'That document type is not configured for your school.';
  if (message.includes('DOCUMENT_NOT_FOUND')) return 'Document not found.';
  return 'Something went wrong. Please try again.';
}

// FR-D06: file a mandatory-paperwork document (police verification, medical
// certificate...) with its expiry date, optionally with the scan attached.
export async function addComplianceDocument(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = complianceDocumentSchema.safeParse({
    staffUserId: formData.get('staffUserId'),
    documentType: formData.get('documentType'),
    expiresOn: formData.get('expiresOn'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const file = formData.get('document');
  let storagePath: string | undefined;
  const admin = supabaseServiceRole();
  if (file && file instanceof File && file.size > 0) {
    if (!['image/jpeg', 'image/png', 'application/pdf'].includes(file.type)) return { error: 'Only PDF, JPEG, and PNG files are accepted.' };
    if (file.size > 10 * 1024 * 1024) return { error: 'Document must be less than 10 MB.' };
    const ext = file.name.includes('.') ? file.name.split('.').pop()!.toLowerCase() : 'pdf';
    storagePath = `${parsed.data.staffUserId}/${crypto.randomUUID()}.${ext}`;
    const { error: uploadError } = await admin.storage.from('staff-docs').upload(storagePath, file, { contentType: file.type, upsert: false });
    if (uploadError) return { error: 'Failed to upload the document file. Please try again.' };
  }

  const { error } = await supabase.rpc('add_staff_compliance_document', {
    p_staff_id: parsed.data.staffUserId,
    p_document_type: parsed.data.documentType,
    p_expires_on: parsed.data.expiresOn,
    p_storage_path: storagePath,
  });
  if (error) {
    if (storagePath) await admin.storage.from('staff-docs').remove([storagePath]);
    return { error: mapError(error.message) };
  }
  revalidatePath('/staff/compliance');
  return { error: null, message: 'Document recorded.' };
}

// Renewal: the same document gets its new expiry; compliance recovers at once
// and the reminder thresholds are re-armed for the new date.
export async function renewDocument(_prev: ActionState, formData: FormData): Promise<ActionState> {
  const parsed = renewDocumentSchema.safeParse({ documentId: formData.get('documentId'), expiresOn: formData.get('expiresOn') });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('set_staff_document_expiry', { p_document_id: parsed.data.documentId, p_expires_on: parsed.data.expiresOn });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/compliance');
  return { error: null, message: 'Expiry date updated.' };
}

export async function runExpiryCheck(): Promise<ActionState> {
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('run_staff_document_expiry_check');
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/compliance');
  return { error: null, message: `${data ?? 0} new reminder(s) generated.` };
}

export async function saveDocumentPolicy(values: Record<string, string>): Promise<{ error: string | null; message?: string }> {
  const p = documentPolicySchema.safeParse(values);
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const code =
    p.data.documentType === 'new'
      ? p.data.label.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^[^a-z]+|_+$/g, '').slice(0, 40)
      : p.data.documentType;
  if (!/^[a-z][a-z0-9_]{1,39}$/.test(code)) return { error: 'Start the document name with a letter.' };
  const supabase = await supabaseServer();
  const { data: existing } = await supabase.from('document_type_policy').select('applies_to_contract_types').eq('document_type', code).maybeSingle();
  const { error } = await supabase.rpc('upsert_document_type_policy', {
    p_document_type: code,
    p_label: p.data.label,
    p_is_mandatory: p.data.mandatory === 'yes',
    p_contract_types: existing?.applies_to_contract_types ?? [],
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/compliance');
  return { error: null, message: 'Document rule saved.' };
}
