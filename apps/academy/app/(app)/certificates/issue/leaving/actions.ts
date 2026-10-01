'use server';

import { revalidatePath } from 'next/cache';
import { issueLeavingCertificateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { renderAndStoreCertificate, type IssuedCertificate } from '@/lib/certificates/issue';

/**
 * FR-T07: the Leaving Certificate issuing action. Same two-phase shape as the
 * Transfer and Character certificates: the database transaction validates,
 * allocates the SLC serial and writes the register row; the PDF is rendered here
 * afterwards, and a render failure voids the row while keeping its serial.
 */

const PATH = '/certificates/issue/leaving';

export type IssueLeavingCertificateState = {
  error: string | null;
  /** True when the refusal means the clerk should use the Transfer Certificate screen instead. */
  useTransferCertificate?: boolean;
  serialNo?: string;
  downloadUrl?: string;
  resultStatus?: string;
};

function issueErrorMessage(message: string): { text: string; transfer?: boolean } | null {
  if (message.includes('require a Transfer Certificate')) return { text: message.replace(/^.*?(Grade \d+ leavers.*)$/s, '$1'), transfer: true };
  if (message.includes('struck off without sitting')) {
    return { text: 'This student was struck off without sitting the board examination. Issue a Transfer Certificate instead.', transfer: true };
  }
  if (message.includes('STUDENT_NOT_COMPLETED')) {
    return { text: 'A Leaving Certificate is for a student who has completed the class. This student has not passed out yet.', transfer: true };
  }
  if (message.includes('LEAVING_CERTIFICATE_ALREADY_ISSUED')) {
    return { text: 'This enrolment already has a live Leaving Certificate. Withdraw it in the register first if a replacement is needed.' };
  }
  if (message.includes('TEMPLATE_NOT_FOUND')) {
    return { text: 'No active Leaving Certificate template for this campus, board and language. Design and activate one first.' };
  }
  if (message.includes('ACADEMIC_SESSION_NOT_FOUND')) return { text: 'This campus has no current academic session to number the certificate against.' };
  if (message.includes('ENROLMENT_NOT_FOUND')) return { text: 'Enrolment not found.' };
  if (message.includes('FORBIDDEN')) return { text: 'You do not have permission to issue certificates here.' };
  return null;
}

export async function issueLeavingCertificate(formData: FormData): Promise<IssueLeavingCertificateState> {
  const parsed = issueLeavingCertificateSchema.safeParse({
    enrolmentId: formData.get('enrolmentId'),
    boardCode: formData.get('boardCode') || undefined,
    language: formData.get('language'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('issue_leaving_certificate', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_language: parsed.data.language,
  });
  if (error || !data) {
    const mapped = error ? issueErrorMessage(error.message) : null;
    return { error: mapped?.text ?? 'Could not issue the certificate.', useTransferCertificate: mapped?.transfer };
  }

  const issued = data as unknown as IssuedCertificate & { result_status: string };
  const stored = await renderAndStoreCertificate(supabase, issued);
  revalidatePath(PATH);
  if (stored.error) return { error: stored.error };
  return { error: null, serialNo: issued.serial_no, downloadUrl: stored.downloadUrl, resultStatus: issued.result_status };
}
