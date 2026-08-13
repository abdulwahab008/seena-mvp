'use server';

import { revalidatePath } from 'next/cache';
import {
  certificateRegisterFilterSchema,
  revokeCertificateSchema,
  setCertificateReplacementSchema,
} from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { RendererUnavailableError, renderPdf } from '@/lib/pdf/render';
import { buildRegisterHtml, registerDate } from '@/lib/certificates/register-html';
import { CERTIFICATE_TYPE_LABELS, readRegister } from '@/lib/certificates/register-query';

/**
 * FR-T08: the two annotations a bound register allows, and the export.
 *
 * Nothing here writes to certificate_issue directly. revoke_certificate()
 * and set_certificate_replacement() own the only two transitions the
 * append-only trigger accepts, so an action that tried to be clever with a
 * direct update would simply be refused — which is the point.
 */

const PATH = '/certificates/register';

export type RegisterActionState = { error: string | null; serialNo?: string; replacedBySerialNo?: string };

export type RegisterExportState = {
  error: string | null;
  rowCount?: number;
  fileName?: string;
  /** A data: URL — see exportCertificateRegister() for why it is not a stored file. */
  downloadUrl?: string;
};

function actionErrorMessage(message: string): string {
  if (message.includes('REVOCATION_REASON_REQUIRED')) return 'A cancellation has to say why.';
  if (message.includes('CERTIFICATE_NOT_ISSUED')) {
    return 'That entry is not live — a voided or already-cancelled certificate stays as it is.';
  }
  if (message.includes('CERTIFICATE_NOT_CANCELLED')) return 'Only a cancelled entry names a replacement.';
  if (message.includes('REPLACEMENT_ALREADY_SET')) return 'That entry already names its replacement.';
  if (message.includes('REPLACEMENT_INVALID')) {
    return 'A replacement must be a live certificate of the same type, for the same student, at the same campus.';
  }
  if (message.includes('CERTIFICATE_ISSUE_NOT_FOUND')) return 'Certificate not found.';
  if (message.includes('certificate register is append-only')) {
    return 'The register is append-only — that entry cannot be changed.';
  }
  if (message.includes('FORBIDDEN')) return 'Only a Principal, Owner or Super Admin can cancel a certificate.';
  return 'Could not update the register.';
}

export async function cancelCertificate(formData: FormData): Promise<RegisterActionState> {
  const parsed = revokeCertificateSchema.safeParse({
    issueId: formData.get('issueId'),
    reason: formData.get('reason'),
    replacementIssueId: formData.get('replacementIssueId') ?? '',
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('revoke_certificate', {
    p_issue_id: parsed.data.issueId,
    p_reason: parsed.data.reason,
    p_replacement_issue_id: parsed.data.replacementIssueId || undefined,
  });
  if (error || !data) return { error: error ? actionErrorMessage(error.message) : 'Could not cancel the certificate.' };

  revalidatePath(PATH);
  return { error: null, serialNo: (data as unknown as { serial_no: string }).serial_no };
}

export async function linkCertificateReplacement(formData: FormData): Promise<RegisterActionState> {
  const parsed = setCertificateReplacementSchema.safeParse({
    cancelledIssueId: formData.get('cancelledIssueId'),
    replacementIssueId: formData.get('replacementIssueId'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data, error } = await supabase.rpc('set_certificate_replacement', {
    p_cancelled_issue_id: parsed.data.cancelledIssueId,
    p_replacement_issue_id: parsed.data.replacementIssueId,
  });
  if (error || !data) return { error: error ? actionErrorMessage(error.message) : 'Could not link the replacement.' };

  revalidatePath(PATH);
  const result = data as unknown as { serial_no: string; replaced_by_serial_no: string };
  return { error: null, serialNo: result.serial_no, replacedBySerialNo: result.replaced_by_serial_no };
}

/**
 * AC3. The rows come from the same readRegister() the page itself uses, so
 * the printout and the screen cannot disagree.
 *
 * The PDF comes back as a data: URL rather than as a file in a bucket, and
 * that is deliberate. Every stored PDF in this schema is one a later request
 * has to be able to re-fetch — an issued certificate is evidence, a
 * timetable export is a link that gets handed round. A register snapshot is
 * neither: the register itself is permanent and can be re-exported at any
 * moment, so storing snapshots would create objects that nothing owns and
 * nothing expires. The inspector is handed the printout, not a link.
 *
 * AC3's "under 20 seconds" is not something this environment can honestly
 * certify — it depends entirely on the machine Chromium runs on. What is
 * real and is checked: the register read is a single indexed query,
 * measured over a 4,235-entry register in supabase/tests/database/
 * certificate_register_immutability.test.sql, and the document is one table
 * with no per-row work beyond escaping.
 */
export async function exportCertificateRegister(formData: FormData): Promise<RegisterExportState> {
  const parsed = certificateRegisterFilterSchema.safeParse({
    campusId: formData.get('campusId') ?? '',
    certificateType: formData.get('certificateType'),
    academicYear: formData.get('academicYear'),
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Choose a certificate type and a year.' };

  const supabase = await supabaseServer();
  const filters = {
    campusId: parsed.data.campusId || '',
    certificateType: parsed.data.certificateType,
    academicYear: parsed.data.academicYear,
  };
  const { rows, continuity } = await readRegister(supabase, filters);

  const {
    data: { user },
  } = await supabase.auth.getUser();
  const [{ data: tenant }, campusResult, appUserResult] = await Promise.all([
    supabase.from('tenant').select('name').limit(1).maybeSingle(),
    filters.campusId
      ? supabase.from('campus').select('name, code').eq('id', filters.campusId).maybeSingle()
      : Promise.resolve({ data: null }),
    user
      ? supabase.from('app_user').select('full_name').eq('user_id', user.id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const campus = campusResult.data;

  const doc = buildRegisterHtml(rows, continuity, {
    schoolName: tenant?.name ?? 'School',
    campusLabel: campus ? `${campus.name} (${campus.code})` : 'All campuses',
    certificateTypeLabel: CERTIFICATE_TYPE_LABELS[filters.certificateType],
    academicYearLabel: String(filters.academicYear),
    printedAt: registerDate(new Date().toISOString()),
    printedBy: appUserResult.data?.full_name ?? null,
  });

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    return {
      error:
        cause instanceof RendererUnavailableError
          ? 'No PDF renderer is available on this server, so the register could not be printed.'
          : 'The register could not be printed.',
    };
  }

  return {
    error: null,
    rowCount: rows.length,
    fileName: `certificate-register-${filters.certificateType}-${filters.academicYear}.pdf`,
    downloadUrl: `data:application/pdf;base64,${pdf.toString('base64')}`,
  };
}
