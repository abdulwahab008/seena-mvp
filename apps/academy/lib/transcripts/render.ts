import type { supabaseServer } from '@/lib/supabase/server';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf, stampPdfTimestamps } from '@/lib/pdf/render';
import { sha256Hex } from '@/lib/certificates/seal';
import { buildTranscriptHtml, collectTranscriptStrings, type TranscriptSnapshot } from './html';

/**
 * FR-J13: everything after issue_transcript() has committed — the
 * "render-transcript-pdf" the FR names, run in the app server like FR-J09's
 * report card renderer (this repo has no edge runtime).
 *
 * The register row and the serial exist before any bytes do, so a render
 * failure cannot rewind the allocator: it voids the row, which stays in the
 * register saying why it never became a document.
 */
type ServerClient = Awaited<ReturnType<typeof supabaseServer>>;

export type IssuedTranscript = {
  issue_id: string;
  serial_no: string;
  storage_path: string;
  snapshot: TranscriptSnapshot;
};

export type StoredTranscript = { error: string | null; serialNo?: string; downloadUrl?: string; checksum?: string };

export const transcriptDownloadPath = (issueId: string) => `/api/transcripts/${issueId}/download`;

export async function renderAndStoreTranscript(supabase: ServerClient, issued: IssuedTranscript): Promise<StoredTranscript> {
  const fail = async (message: string, reason: string): Promise<StoredTranscript> => {
    await supabase.rpc('void_transcript_issue', { p_issue_id: issued.issue_id, p_reason: reason });
    return { error: message };
  };

  const font = resolveNastaliqFont();
  const coverage = font ? checkGlyphCoverage(collectTranscriptStrings(issued.snapshot), parseCmapRanges(font.bytes)) : null;
  if (coverage && coverage.missing.length > 0) {
    return fail(
      `The transcript cannot be typeset — ${coverage.missing.length} character(s) are missing from the Urdu font.`,
      `MISSING_GLYPHS: ${coverage.missing.join(',')}`,
    );
  }

  let pdf: Buffer;
  try {
    pdf = await renderPdf(buildTranscriptHtml(issued.snapshot, font));
  } catch (cause) {
    return cause instanceof RendererUnavailableError
      ? fail('No PDF renderer is available on this server, so no transcript was produced.', 'RENDERER_UNAVAILABLE')
      : fail('The transcript could not be rendered, so none was produced.', 'RENDER_FAILED');
  }
  // The document's own date, not the clock: a re-render is the same bytes.
  const bytes = stampPdfTimestamps(new Uint8Array(pdf), new Date(`${issued.snapshot.issued_on ?? new Date().toISOString().slice(0, 10)}T00:00:00Z`));

  const { error: uploadError } = await supabase.storage
    .from('transcripts')
    .upload(issued.storage_path, bytes, { contentType: 'application/pdf', upsert: false });
  if (uploadError) return fail('The transcript could not be stored, so none was produced.', 'UPLOAD_FAILED');

  const { data: stored } = await supabase.storage.from('transcripts').download(issued.storage_path);
  if (!stored) return fail('The stored transcript could not be read back.', 'STORED_OBJECT_UNREADABLE');
  const checksum = sha256Hex(new Uint8Array(await stored.arrayBuffer()));
  if (checksum !== sha256Hex(bytes)) return fail('The stored transcript does not match what was rendered.', 'UPLOAD_CORRUPT');

  const { error: sealError } = await supabase.rpc('attach_transcript_pdf', { p_issue_id: issued.issue_id, p_sha256: checksum });
  if (sealError) return fail('The transcript could not be sealed, so none was produced.', `SEAL_FAILED: ${sealError.message}`);

  return { error: null, serialNo: issued.serial_no, downloadUrl: transcriptDownloadPath(issued.issue_id), checksum };
}
