import { headers } from 'next/headers';
import type { supabaseServer } from '@/lib/supabase/server';
import { buildCertificateHtml, collectCertificateStrings, snapshotToPayload, type CertificateSnapshot } from './html';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf } from '@/lib/pdf/render';
import { checkSealResolution, sha256Hex } from './seal';

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
 *
 * FR-T09 adds three steps inside that same sequence, all before the link is
 * handed over and all on the same void-on-failure path:
 *
 *   1. the seal's images are checked for print resolution BEFORE anything is
 *      rendered, so an inadequate signature costs a serial rather than
 *      producing a blurry statutory document,
 *   2. the object is read back out of the bucket and the digest is taken of
 *      what the bucket actually holds — not of what was sent to it — so the
 *      recorded hash is a statement about the stored bytes,
 *   3. that digest is sealed onto the register row, write-once, through
 *      FR-T08's fourth transition. A certificate whose digest could not be
 *      recorded is voided: an unsealed document is not evidence, and issuing
 *      one silently would hollow out every later verification.
 */

type ServerClient = Awaited<ReturnType<typeof supabaseServer>>;

const MIME_BY_EXT: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };

/** The shape every issue_*_certificate() RPC returns, as far as this module cares. */
export type IssuedCertificate = {
  issue_id: string;
  serial_no: string;
  pdf_path: string;
  payload_snapshot: CertificateSnapshot;
};

export type StoredCertificate = { error: string | null; downloadUrl?: string; pdfSha256?: string };

async function assetDataUri(supabase: ServerClient, storagePath: string | null): Promise<string | null> {
  if (!storagePath) return null;
  const { data } = await supabase.storage.from('branding').download(storagePath);
  if (!data) return null;
  const mime = MIME_BY_EXT[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  return `data:${mime};base64,${Buffer.from(await data.arrayBuffer()).toString('base64')}`;
}

/**
 * FR-T09: the route that verifies before it serves, not a signed bucket URL.
 * Absolute because it is handed to a user as a link and because the e2e
 * suite fetches it directly; relative when there is no request to read a
 * host from, which cannot happen from a server action but is not worth
 * throwing over.
 */
export function certificateDownloadPath(issueId: string): string {
  return `/api/certificates/${issueId}/download`;
}

async function certificateDownloadUrl(issueId: string): Promise<string> {
  const requestHeaders = await headers();
  const host = requestHeaders.get('host');
  if (!host) return certificateDownloadPath(issueId);
  const proto = requestHeaders.get('x-forwarded-proto') ?? (host.startsWith('localhost') || host.startsWith('127.') ? 'http' : 'https');
  return `${proto}://${host}${certificateDownloadPath(issueId)}`;
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

  // AC1's "at 300 DPI", before a single byte is rendered. Nothing downstream
  // can add detail an image does not carry, so the honest answer to a
  // 200-pixel signature in a 45mm box is to refuse it rather than to upscale
  // it onto a board document.
  const seal = issued.payload_snapshot.seal ?? null;
  if (seal) {
    const resolution = checkSealResolution(seal);
    if (!resolution.ok) {
      return fail(
        `The certificate cannot be sealed — ${resolution.failures[0]}. Upload a higher-resolution image and issue again.`,
        `SEAL_RESOLUTION_TOO_LOW: ${resolution.failures.join('; ')}`,
      );
    }
  }

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

  const signatureDataUri = await assetDataUri(supabase, seal?.signature_storage_path ?? null);
  // A signing identity that resolves but whose image cannot be read is a
  // document that would print with a blank where a signature belongs.
  if (seal && !signatureDataUri) {
    return fail(
      'The signature image could not be read, so nothing was issued.',
      `SIGNATURE_ASSET_UNREADABLE: ${seal.signature_storage_path}`,
    );
  }

  const doc = buildCertificateHtml(payload, font, {
    letterheadDataUri: await assetDataUri(supabase, issued.payload_snapshot.letterhead_storage_path),
    logoDataUri: await assetDataUri(supabase, issued.payload_snapshot.logo_storage_path),
    signatureDataUri,
    stampDataUri: await assetDataUri(supabase, seal?.stamp_storage_path ?? null),
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

  // FR-T09. The digest is taken of what the BUCKET holds, read back, rather
  // than of the buffer that was sent to it — the recorded hash has to be a
  // statement about the stored object, because the stored object is what
  // every later download compares against.
  const { data: storedBlob } = await supabase.storage.from('certificates').download(issued.pdf_path);
  if (!storedBlob) return fail('The stored certificate could not be read back, so nothing was issued.', 'STORED_OBJECT_UNREADABLE');
  const storedBytes = new Uint8Array(await storedBlob.arrayBuffer());
  const pdfSha256 = sha256Hex(storedBytes);
  if (pdfSha256 !== sha256Hex(new Uint8Array(pdf))) {
    return fail('The stored certificate does not match the document that was rendered, so nothing was issued.', 'UPLOAD_CORRUPT');
  }

  // Write-once, through FR-T08's fourth transition. An unsealed certificate
  // is a document no download can ever verify, so it is not issued at all.
  const { error: sealError } = await supabase.rpc('attach_certificate_pdf_digest', {
    p_issue_id: issued.issue_id,
    p_sha256: pdfSha256,
  });
  if (sealError) return fail('The certificate could not be sealed, so nothing was issued.', `SEAL_FAILED: ${sealError.message}`);

  return { error: null, downloadUrl: await certificateDownloadUrl(issued.issue_id), pdfSha256 };
}
