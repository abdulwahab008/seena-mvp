'use server';

import { revalidatePath } from 'next/cache';
import { issueTransferCertificateSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import {
  buildCertificateHtml,
  collectCertificateStrings,
  snapshotToPayload,
  type CertificateSnapshot,
} from '@/lib/certificates/html';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf } from '@/lib/pdf/render';

/**
 * FR-T03: the issuing action.
 *
 * The order is load-bearing. issue_transfer_certificate() is one database
 * transaction that validates, allocates the serial and writes the register
 * row; the render happens here, afterwards, because Postgres cannot render
 * a PDF. That means a render failure cannot be rolled back into the
 * allocator, and FR-T02 forbids rewinding the counter (a rewound number is
 * a number that eventually gets printed twice). So the failure path is
 * void_certificate_issue(): the enrolment goes back to active, and the row
 * stays in the register carrying its serial and saying why. A number the
 * register accounts for is exactly what FR-T02's user story is protecting;
 * a hole is not.
 */

const PATH = '/certificates/issue';
const MIME_BY_EXT: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };
/** Long enough for an officer to hand the file over; short enough not to be a link that leaks. */
const DOWNLOAD_URL_TTL_SECONDS = 60 * 60;

export type IssueTransferCertificateState = {
  error: string | null;
  serialNo?: string;
  downloadUrl?: string;
  /** AC2: the serial of the certificate that already exists, for the UI to name. */
  existingSerial?: string;
};

async function assetDataUri(
  supabase: Awaited<ReturnType<typeof supabaseServer>>,
  storagePath: string | null,
): Promise<string | null> {
  if (!storagePath) return null;
  const { data } = await supabase.storage.from('branding').download(storagePath);
  if (!data) return null;
  const mime = MIME_BY_EXT[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  return `data:${mime};base64,${Buffer.from(await data.arrayBuffer()).toString('base64')}`;
}

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

  const issued = data as unknown as {
    issue_id: string;
    serial_no: string;
    pdf_path: string;
    payload_snapshot: CertificateSnapshot;
  };

  // From here the register row exists and holds a serial. Everything below
  // either produces the document or gives the row back as void.
  const fail = async (userMessage: string, reason: string): Promise<IssueTransferCertificateState> => {
    await supabase.rpc('void_certificate_issue', { p_issue_id: issued.issue_id, p_reason: reason });
    revalidatePath(PATH);
    return { error: userMessage };
  };

  const payload = snapshotToPayload(issued.payload_snapshot);
  const font = resolveNastaliqFont();
  const coverage = font ? checkGlyphCoverage(collectCertificateStrings(payload), parseCmapRanges(font.bytes)) : null;
  if (coverage && coverage.missing.length > 0) {
    // A tofu box on a board document is a document the board rejects.
    return fail(
      `The certificate cannot be typeset — ${coverage.missing.length} character(s) are missing from the Urdu font.`,
      `MISSING_GLYPHS: ${coverage.missing.join(',')}`,
    );
  }

  const doc = buildCertificateHtml(payload, font, {
    letterheadDataUri: await assetDataUri(supabase, issued.payload_snapshot.letterhead_storage_path),
    logoDataUri: await assetDataUri(supabase, issued.payload_snapshot.logo_storage_path),
  });

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    return fail(
      cause instanceof RendererUnavailableError
        ? 'No PDF renderer is available on this server, so nothing was issued.'
        : 'The certificate could not be rendered, so nothing was issued.',
      cause instanceof RendererUnavailableError ? 'RENDERER_UNAVAILABLE' : 'RENDER_FAILED',
    );
  }

  // upsert: false on purpose — a serial names exactly one document, and
  // overwriting the bytes of an issued certificate is what FR-T09's tamper
  // check exists to detect.
  const { error: uploadError } = await supabase.storage
    .from('certificates')
    .upload(issued.pdf_path, new Uint8Array(pdf), { contentType: 'application/pdf', upsert: false });
  if (uploadError) return fail('The certificate could not be stored, so nothing was issued.', 'UPLOAD_FAILED');

  const { data: signed } = await supabase.storage
    .from('certificates')
    .createSignedUrl(issued.pdf_path, DOWNLOAD_URL_TTL_SECONDS);

  revalidatePath(PATH);
  return { error: null, serialNo: issued.serial_no, downloadUrl: signed?.signedUrl };
}
