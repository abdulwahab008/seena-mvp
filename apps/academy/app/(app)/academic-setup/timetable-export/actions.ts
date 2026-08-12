'use server';

import { revalidatePath } from 'next/cache';
import { requestTimetableExportSchema } from '@/lib/validation';
import { supabaseServer } from '@/lib/supabase/server';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont, NASTALIQ_FONT_FAMILY } from '@/lib/pdf/font';
import { buildExportHtml } from '@/lib/timetable-export/html';
import { collectUrduStrings, type ExportPayload } from '@/lib/timetable-export/layout';
import { RendererUnavailableError, pdfPageCount, renderPdf } from '@/lib/pdf/render';

export type TimetableExportState = {
  error: string | null;
  jobId?: string;
  pageCount?: number;
  missingGlyphCount?: number;
  downloadUrl?: string;
};

const SIGNED_URL_SECONDS = 60 * 60 * 24;

const MIME_BY_EXT: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };

async function logoDataUri(
  supabase: Awaited<ReturnType<typeof supabaseServer>>,
  storagePath: string | null,
): Promise<string | null> {
  if (!storagePath) return null;
  const { data, error } = await supabase.storage.from('branding').download(storagePath);
  if (error || !data) return null;
  const mime = MIME_BY_EXT[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  const base64 = Buffer.from(await data.arrayBuffer()).toString('base64');
  return `data:${mime};base64,${base64}`;
}

// FR-F15: the export runs to completion inside the request that asked for
// it — the same deliberate stand-in FR-T14 documented, for the same reason
// (no queue, no worker, no pg_cron in this environment).
// request_timetable_export / complete_timetable_export /
// fail_timetable_export are the seam a real worker would sit behind, and
// nothing below reads a scope from the form: the job row is the only
// authority on which sections and which teacher this PDF may contain.
export async function triggerTimetableExport(_prev: TimetableExportState, formData: FormData): Promise<TimetableExportState> {
  const parsed = requestTimetableExportSchema.safeParse({
    versionId: formData.get('versionId'),
    layout: formData.get('layout'),
    staffId: formData.get('staffId') || undefined,
  });
  if (!parsed.success) return { error: parsed.error.issues[0]?.message ?? 'Invalid input.' };

  const supabase = await supabaseServer();
  const { data: jobId, error: requestError } = await supabase.rpc('request_timetable_export', {
    p_version_id: parsed.data.versionId,
    p_layout: parsed.data.layout,
    p_staff_id: parsed.data.staffId || undefined,
  });
  if (requestError || !jobId) {
    if (requestError?.message.includes('EXPORT_SCOPE_FORBIDDEN')) return { error: 'You can only export your own timetable sheet.' };
    if (requestError?.message.includes('FORBIDDEN')) return { error: 'You do not have permission to export this timetable.' };
    if (requestError?.message.includes('VERSION_NOT_FOUND')) return { error: 'Timetable version not found.' };
    if (requestError?.message.includes('STAFF_NOT_FOUND')) return { error: 'Staff member not found.' };
    return { error: 'Could not start the export.' };
  }

  const fail = async (message: string, userMessage: string): Promise<TimetableExportState> => {
    await supabase.rpc('fail_timetable_export', { p_job_id: jobId, p_error: message });
    revalidatePath('/academic-setup/timetable-export');
    return { error: userMessage };
  };

  const { data: payloadJson, error: payloadError } = await supabase.rpc('timetable_export_payload', { p_job_id: jobId });
  if (payloadError || !payloadJson) return fail(payloadError?.message ?? 'payload unavailable', 'Could not read the timetable.');
  const payload = payloadJson as unknown as ExportPayload;

  const font = resolveNastaliqFont();
  const coverage = font
    ? checkGlyphCoverage(collectUrduStrings(payload), parseCmapRanges(font.bytes))
    : { checkedCodepoints: 0, missing: [] };

  const doc = buildExportHtml(payload, font, await logoDataUri(supabase, payload.logo_storage_path));

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    if (cause instanceof RendererUnavailableError) {
      return fail('RENDERER_UNAVAILABLE', 'No PDF renderer is available on this server.');
    }
    return fail(cause instanceof Error ? cause.message : 'render failed', 'Could not render the timetable PDF.');
  }

  const filePath = `${payload.campus.id}/${jobId}/timetable-${payload.job.layout}.pdf`;
  const { error: uploadError } = await supabase.storage
    .from('timetable-exports')
    .upload(filePath, pdf, { contentType: 'application/pdf', upsert: true });
  if (uploadError) return fail(uploadError.message, 'Export failed while writing the PDF file.');

  // AC5: 24 hours. A request the next morning is past the signature's own
  // expiry and Storage answers 403 — not something this suite can wait out,
  // so the expiry the link was minted with is what gets recorded.
  const { data: signed, error: signError } = await supabase.storage
    .from('timetable-exports')
    .createSignedUrl(filePath, SIGNED_URL_SECONDS);
  if (signError || !signed) return fail(signError?.message ?? 'could not sign url', 'Export failed while creating the download link.');

  const pageCount = pdfPageCount(pdf);
  const { error: completeError } = await supabase.rpc('complete_timetable_export', {
    p_job_id: jobId,
    p_file_path: filePath,
    p_page_count: pageCount,
    p_missing_glyph_count: coverage.missing.length,
    p_font_family: font ? NASTALIQ_FONT_FAMILY : undefined,
    p_download_url: signed.signedUrl,
    p_expires_hours: 24,
  });
  if (completeError) return { error: 'Export finished but could not be recorded.' };

  revalidatePath('/academic-setup/timetable-export');
  return {
    error: null,
    jobId,
    pageCount,
    missingGlyphCount: coverage.missing.length,
    downloadUrl: signed.signedUrl,
  };
}
