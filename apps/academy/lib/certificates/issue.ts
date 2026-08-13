import type { supabaseServer } from '@/lib/supabase/server';
import { buildCertificateHtml, collectCertificateStrings, snapshotToPayload, type CertificateSnapshot } from './html';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf } from '@/lib/pdf/render';

/**
 * FR-T03/FR-T05: everything that happens AFTER the issuance transaction has
 * committed, shared by every certificate type.
 *
 * The order is load-bearing and is the same for a Transfer and a Character
 * Certificate. issue_*_certificate() is one database transaction that
 * validates, allocates the serial and writes the register row; the render
 * happens here, afterwards, because Postgres cannot render a PDF. That means
 * a render failure cannot be rolled back into the allocator, and FR-T02
 * forbids rewinding the counter (a rewound number is a number that
 * eventually gets printed twice). So the failure path is
 * void_certificate_issue(): the row stays in the register carrying its
 * serial and saying why, and — for a transfer — the enrolment goes back to
 * active. A number the register accounts for is exactly what FR-T02's user
 * story is protecting; a hole is not.
 */

type ServerClient = Awaited<ReturnType<typeof supabaseServer>>;

const MIME_BY_EXT: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };
/** Long enough for an officer to hand the file over; short enough not to be a link that leaks. */
export const DOWNLOAD_URL_TTL_SECONDS = 60 * 60;

/** The shape every issue_*_certificate() RPC returns, as far as this module cares. */
export type IssuedCertificate = {
  issue_id: string;
  serial_no: string;
  pdf_path: string;
  payload_snapshot: CertificateSnapshot;
};

export type StoredCertificate = { error: string | null; downloadUrl?: string };

async function assetDataUri(supabase: ServerClient, storagePath: string | null): Promise<string | null> {
  if (!storagePath) return null;
  const { data } = await supabase.storage.from('branding').download(storagePath);
  if (!data) return null;
  const mime = MIME_BY_EXT[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  return `data:${mime};base64,${Buffer.from(await data.arrayBuffer()).toString('base64')}`;
}

export async function renderAndStoreCertificate(
  supabase: ServerClient,
  issued: IssuedCertificate,
): Promise<StoredCertificate> {
  // From here the register row exists and holds a serial. Everything below
  // either produces the document or gives the row back as void.
  const fail = async (userMessage: string, reason: string): Promise<StoredCertificate> => {
    await supabase.rpc('void_certificate_issue', { p_issue_id: issued.issue_id, p_reason: reason });
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

  return { error: null, downloadUrl: signed?.signedUrl };
}
