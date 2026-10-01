'use server';

import { revalidatePath } from 'next/cache';
import { certificateTemplateSchema, issueCertificateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type CertificateState = { error: string | null; message?: string | null; certificateId?: string | null; needsOverride?: boolean };

function mapError(message: string): string {
  if (message.includes('CERTIFICATE_BLOCKED_PENDING_OWNER_OVERRIDE'))
    return 'This person has an open termination for misconduct. An experience certificate can only be released by the Owner, with a written reason.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to do that.';
  if (message.includes('STAFF_NOT_FOUND')) return 'Staff member not found.';
  if (message.includes('TEMPLATE_NOT_FOUND')) return 'The certificate template is missing.';
  if (message.includes('NUMBER_FORMAT_NEEDS_SEQ')) return 'The number format must contain {seq4}.';
  return 'Something went wrong. Please try again.';
}

export async function issueCertificate(_prev: CertificateState, formData: FormData): Promise<CertificateState> {
  const p = issueCertificateSchema.safeParse({
    staffId: formData.get('staffId'),
    certType: formData.get('certType'),
    overrideReason: (formData.get('overrideReason') as string | null)?.trim() || undefined,
  });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('issue_staff_certificate', {
    p_staff_id: p.data.staffId,
    p_cert_type: p.data.certType,
    p_override_reason: p.data.overrideReason,
  });
  if (error) return { error: mapError(error.message), needsOverride: error.message.includes('CERTIFICATE_BLOCKED_PENDING_OWNER_OVERRIDE') };
  revalidatePath('/staff/certificates');
  return { error: null, message: 'Certificate issued.', certificateId: data as string };
}

export async function saveTemplate(_prev: CertificateState, formData: FormData): Promise<CertificateState> {
  const p = certificateTemplateSchema.safeParse({
    certType: formData.get('certType'),
    title: formData.get('title'),
    bodyHtml: formData.get('bodyHtml'),
    numberFormat: formData.get('numberFormat'),
  });
  if (!p.success) return { error: p.error.issues[0]?.message ?? 'Invalid input.' };
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc('upsert_staff_certificate_template', {
    p_cert_type: p.data.certType,
    p_title: p.data.title,
    p_body_html: p.data.bodyHtml,
    p_number_format: p.data.numberFormat,
  });
  if (error) return { error: mapError(error.message) };
  revalidatePath('/staff/certificates');
  return { error: null, message: 'Template saved. It applies to certificates issued from now on.' };
}
