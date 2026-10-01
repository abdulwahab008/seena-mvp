'use server';

import { headers } from 'next/headers';
import { revalidatePath } from 'next/cache';
import { certificateRequestDecisionSchema, type CertificateRequestDecisionInput } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { renderAndStoreCertificate, type IssuedCertificate } from '@/lib/certificates/issue';

/**
 * FR-T06: an officer decides a bonafide request.
 *
 * Approval is the same two-phase shape as every certificate: the database
 * transaction issues the register row (status approved), the PDF is rendered
 * here, and only when it is safely stored is the request marked issued and the
 * guardian's WhatsApp message queued. A failed render voids the issue, leaves
 * the request approved, and approving again issues afresh.
 */

const PATH = '/certificates/requests';

export type DecisionState = { error: string | null; notice?: string };

function errorMessage(message: string): string {
  if (message.includes('TEMPLATE_NOT_FOUND')) return 'No active Bonafide Certificate template for this campus. Design and activate one first.';
  if (message.includes('STUDENT_NOT_ENROLLED')) return 'A bonafide certificate is for a currently enrolled student, and this student is not.';
  if (message.includes('REQUEST_NOT_PENDING')) return 'This request has already been decided.';
  if (message.includes('REASON_REQUIRED')) return 'Say why the request is being rejected.';
  if (message.includes('ACADEMIC_SESSION_NOT_FOUND')) return 'This campus has no current academic session to number the certificate against.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to decide certificate requests.';
  return 'Could not complete that.';
}

async function requestOrigin(): Promise<string | null> {
  const h = await headers();
  const host = h.get('host');
  if (!host) return null;
  const proto = h.get('x-forwarded-proto') ?? (host.startsWith('localhost') || host.startsWith('127.') ? 'http' : 'https');
  return `${proto}://${host}`;
}

export async function decideCertificateRequest(input: CertificateRequestDecisionInput): Promise<DecisionState> {
  const parsed = certificateRequestDecisionSchema.safeParse(input);
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };
  const { requestId, decision, reason, language } = parsed.data;
  const supabase = await supabaseServer();

  if (decision === 'reject') {
    const { error } = await supabase.rpc('reject_certificate_request', { p_request_id: requestId, p_reason: reason ?? '' });
    if (error) return { error: errorMessage(error.message) };
    revalidatePath(PATH);
    return { error: null, notice: 'Request rejected.' };
  }

  const { data, error } = await supabase.rpc('approve_certificate_request', { p_request_id: requestId, p_language: language });
  if (error || !data) return { error: errorMessage(error?.message ?? '') };

  const stored = await renderAndStoreCertificate(supabase, data as unknown as IssuedCertificate);
  revalidatePath(PATH);
  if (stored.error) return { error: stored.error };

  const marked = await supabase.rpc('mark_certificate_request_issued', { p_request_id: requestId });
  if (marked.error) return { error: errorMessage(marked.error.message) };

  const origin = await requestOrigin();
  if (!origin) return { error: null, notice: 'Certificate issued. The WhatsApp message could not be queued because the site address is unknown.' };
  const { data: queued, error: queueError } = await supabase.rpc('queue_certificate_ready_message', { p_request_id: requestId, p_base_url: origin });
  if (queueError) return { error: null, notice: 'Certificate issued, but the WhatsApp message could not be queued.' };
  const q = queued as unknown as { queued: boolean; reason?: string };
  return {
    error: null,
    notice: q.queued ? 'Certificate issued and a WhatsApp message with a 7-day link has been queued.' : 'Certificate issued. The guardian has no phone number on file, so no message was sent.',
  };
}
