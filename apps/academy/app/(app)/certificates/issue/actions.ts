'use server';

import { revalidatePath } from 'next/cache';
import { issueTransferCertificateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { renderAndStoreCertificate, type IssuedCertificate } from '@/lib/certificates/issue';

/**
 * FR-T03: the issuing action.
 *
 * Everything after the issuance transaction — the glyph check, the render,
 * the upload and the void-on-failure — is lib/certificates/issue.ts, shared
 * with FR-T05's character certificates because the sequence and its failure
 * handling are properties of the register rather than of a certificate type.
 */

const PATH = '/certificates/issue';

export type IssueTransferCertificateState = {
  error: string | null;
  serialNo?: string;
  downloadUrl?: string;
  /** AC2: the serial of the certificate that already exists, for the UI to name. */
  existingSerial?: string;
};

function issueErrorMessage(message: string): string | null {
  if (message.includes('ENROLMENT_NOT_ACTIVE')) {
    return 'This student is not currently enrolled, so no Transfer Certificate can be issued.';
  }
  if (message.includes('LEAVING_DATE_BEFORE_ADMISSION')) return 'The leaving date cannot precede the date of admission.';
  if (message.includes('TEMPLATE_NOT_FOUND')) {
    return 'No active Transfer Certificate template for this campus, board and language. Design and activate one first.';
  }
  if (message.includes('ENROLMENT_NOT_FOUND')) return 'Enrolment not found.';
  if (message.includes('FORBIDDEN')) return 'You do not have permission to issue certificates here.';
  return null;
}

export async function issueTransferCertificate(formData: FormData): Promise<IssueTransferCertificateState> {
  const parsed = issueTransferCertificateSchema.safeParse({
    enrolmentId: formData.get('enrolmentId'),
    leavingDate: formData.get('leavingDate'),
    reason: formData.get('reason') ?? '',
    conduct: formData.get('conduct') ?? '',
    boardCode: formData.get('boardCode') ?? '',
    language: formData.get('language'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('issue_transfer_certificate', {
    p_enrolment_id: parsed.data.enrolmentId,
    p_leaving_date: parsed.data.leavingDate,
    p_reason: parsed.data.reason || undefined,
    p_conduct: parsed.data.conduct || undefined,
    p_board_code: parsed.data.boardCode || undefined,
    p_language: parsed.data.language,
  });

  if (error || !data) {
    // AC2. The serial travels in the exception message itself rather than
    // only in DETAIL, so the officer is told which document already exists
    // without a second round trip and without depending on PostgREST
    // preserving an error's DETAIL field.
    const already = error?.message.match(/TC_ALREADY_ISSUED:\s*(\S+)/);
    if (already) {
      return {
        error: `TC already issued, serial ${already[1]} - use Duplicate instead.`,
        existingSerial: already[1],
      };
    }
    return { error: (error && issueErrorMessage(error.message)) ?? 'Could not issue the certificate.' };
  }

  const issued = data as unknown as IssuedCertificate;
  const stored = await renderAndStoreCertificate(supabase, issued);
  revalidatePath(PATH);
  if (stored.error) return { error: stored.error };

  return { error: null, serialNo: issued.serial_no, downloadUrl: stored.downloadUrl };
}
