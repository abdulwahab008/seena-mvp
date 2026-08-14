import type { supabaseServer } from '@/lib/supabase/server';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf, stampPdfTimestamps } from '@/lib/pdf/render';
import { sha256Hex } from '@/lib/certificates/seal';
import { buildReportCardHtml, collectReportCardStrings, type ReportCardSnapshot } from './html';

/**
 * FR-J09: everything that happens after begin_report_card() has committed.
 *
 * The order is FR-T03's, for FR-T03's reason: Postgres cannot render a PDF,
 * so the revision number and the storage path are reserved in one
 * transaction and the bytes are produced afterwards. A render failure
 * therefore cannot be rolled back into the allocator, and rewinding a
 * revision number would let the next attempt reuse a number already printed
 * on a document in a parent's hand. So the failure path is
 * void_report_card(): the row stays in the register carrying its revision and
 * saying why it never became a document.
 *
 * FR-J09's own addition to that sequence is the timestamp stamp. The PDF's
 * CreationDate is set from the snapshot's rendered_at rather than from the
 * clock, so re-rendering revision 1 from revision 1's snapshot produces the
 * same bytes and therefore the same digest — which is what makes `checksum` a
 * statement about the document instead of about the minute it was produced.
 */

type ServerClient = Awaited<ReturnType<typeof supabaseServer>>;

const MIME_BY_EXT: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };

export type ReservedReportCard = {
  report_card_id: string;
  revision_no: number;
  storage_path: string;
  payload_snapshot: ReportCardSnapshot;
};

export type StoredReportCard = { error: string | null; downloadUrl?: string; checksum?: string; revisionNo?: number };

async function assetDataUri(supabase: ServerClient, bucket: string, storagePath: string | null): Promise<string | null> {
  if (!storagePath) return null;
  const { data } = await supabase.storage.from(bucket).download(storagePath);
  if (!data) return null;
  const mime = MIME_BY_EXT[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  return `data:${mime};base64,${Buffer.from(await data.arrayBuffer()).toString('base64')}`;
}

/**
 * Relative, unlike FR-T03's certificate equivalent. That one resolves an
 * absolute URL out of next/headers because a certificate link is handed to a
 * person; a report card is only ever fetched from the same origin that
 * produced it, and keeping this module free of next/headers is what lets the
 * byte-stability check re-render a stored snapshot outside a request.
 */
export function reportCardDownloadPath(reportCardId: string): string {
  return `/api/report-cards/${reportCardId}/download`;
}

/**
 * The document, from the snapshot and nothing else. Exported on its own so a
 * reprint and the byte-stability check render through exactly the code path
 * the original did — a second builder would be a second document.
 */
export async function renderReportCardPdf(
  supabase: ServerClient,
  snapshot: ReportCardSnapshot,
): Promise<{ pdf: Uint8Array } | { error: string; reason: string }> {
  const font = resolveNastaliqFont();
  const coverage = font ? checkGlyphCoverage(collectReportCardStrings(snapshot), parseCmapRanges(font.bytes)) : null;
  if (coverage && coverage.missing.length > 0) {
    // A tofu box where a child's name belongs is not a document to hand over.
    return {
      error: `The report card cannot be typeset — ${coverage.missing.length} character(s) are missing from the Urdu font.`,
      reason: `MISSING_GLYPHS: ${coverage.missing.join(',')}`,
    };
  }

  const doc = buildReportCardHtml(snapshot, font, {
    letterheadDataUri: await assetDataUri(supabase, 'branding', snapshot.branding.letterhead_storage_path),
    logoDataUri: await assetDataUri(supabase, 'branding', snapshot.branding.logo_storage_path),
    signatureDataUri: await assetDataUri(supabase, 'branding', snapshot.branding.signature_storage_path),
    stampDataUri: await assetDataUri(supabase, 'branding', snapshot.branding.stamp_storage_path),
    // The requirement text names the student's photograph, and student.photo_path
    // is carried in the snapshot for it — but that column has had no writer and
    // no bucket since it was created (FR-T06 recorded the same finding), so
    // there is nothing to fetch and inventing a bucket here would be a photo
    // upload feature smuggled into a print FR. The card prints the ruled box
    // instead, which is what a school pastes a photograph into today.
    photoDataUri: null,
  });

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    return cause instanceof RendererUnavailableError
      ? { error: 'No PDF renderer is available on this server, so no card was produced.', reason: 'RENDERER_UNAVAILABLE' }
      : { error: 'The report card could not be rendered, so no card was produced.', reason: 'RENDER_FAILED' };
  }

  // See the header: the document's own date, not the clock, so revision 1
  // renders to the same bytes today and in 2030.
  return { pdf: stampPdfTimestamps(new Uint8Array(pdf), new Date(snapshot.rendered_at)) };
}

export async function renderAndStoreReportCard(
  supabase: ServerClient,
  reserved: ReservedReportCard,
): Promise<StoredReportCard> {
  const fail = async (userMessage: string, reason: string): Promise<StoredReportCard> => {
    await supabase.rpc('void_report_card', { p_report_card_id: reserved.report_card_id, p_reason: reason });
    return { error: userMessage };
  };

  const rendered = await renderReportCardPdf(supabase, reserved.payload_snapshot);
  if ('error' in rendered) return fail(rendered.error, rendered.reason);

  // upsert: false on purpose — a revision names exactly one document, and
  // overwriting the bytes behind an issued revision is what the checksum
  // exists to detect.
  const { error: uploadError } = await supabase.storage
    .from('report-cards')
    .upload(reserved.storage_path, rendered.pdf, { contentType: 'application/pdf', upsert: false });
  if (uploadError) return fail('The report card could not be stored, so no card was produced.', 'UPLOAD_FAILED');

  // FR-T09: the digest is of what the BUCKET holds, read back, because the
  // stored object is what every later download compares against.
  const { data: storedBlob } = await supabase.storage.from('report-cards').download(reserved.storage_path);
  if (!storedBlob) return fail('The stored report card could not be read back, so no card was produced.', 'STORED_OBJECT_UNREADABLE');
  const storedBytes = new Uint8Array(await storedBlob.arrayBuffer());
  const checksum = sha256Hex(storedBytes);
  if (checksum !== sha256Hex(rendered.pdf)) {
    return fail('The stored report card does not match what was rendered, so no card was produced.', 'UPLOAD_CORRUPT');
  }

  const { error: sealError } = await supabase.rpc('attach_report_card_pdf', {
    p_report_card_id: reserved.report_card_id,
    p_sha256: checksum,
  });
  if (sealError) return fail('The report card could not be sealed, so no card was produced.', `SEAL_FAILED: ${sealError.message}`);

  return {
    error: null,
    downloadUrl: reportCardDownloadPath(reserved.report_card_id),
    checksum,
    revisionNo: reserved.revision_no,
  };
}
