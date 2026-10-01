'use server';

import { revalidatePath } from 'next/cache';
import { certificateRequestSchema, type CertificateRequestInput } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';

export type RequestResult = { error: 'invalid' | 'limit' | 'notFound' | 'generic' | null; detail?: string };

/**
 * FR-T06: a guardian asks for a bonafide certificate.
 *
 * A child the caller is not linked to comes back from the database as zero
 * rows, and is reported here with the same generic message as any other
 * request that did not go through, so the portal never confirms whether a
 * student exists.
 */
export async function submitCertificateRequest(input: CertificateRequestInput): Promise<RequestResult> {
  const parsed = certificateRequestSchema.safeParse(input);
  if (!parsed.success) return { error: 'invalid', detail: parsed.error.issues[0]?.message };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('submit_certificate_request', {
    p_student_id: parsed.data.studentId,
    p_purpose: parsed.data.purpose,
    p_justification: parsed.data.justification || undefined,
  });
  if (error) {
    if (error.message.includes('daily limit of 3 requests reached')) return { error: 'limit' };
    if (error.message.includes('chk_cert_request_other_justification')) return { error: 'invalid', detail: 'Please explain in at least 15 characters' };
    return { error: 'generic' };
  }
  if (!data || (Array.isArray(data) && data.length === 0)) return { error: 'notFound' };
  revalidatePath('/portal/certificates');
  return { error: null };
}
