import { NextResponse, type NextRequest } from 'next/server';
import { supabaseServer } from '@/lib/supabase/server';
import { buildCertificateHtml, collectCertificateStrings, type CertificatePreviewPayload } from '@/lib/certificates/html';
import { NASTALIQ_FONT_FAMILY, checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { RendererUnavailableError, renderPdf } from '@/lib/pdf/render';

/**
 * FR-T01: renders a template as a real PDF, on demand, for whoever is
 * signed in — the "prove it prints" half of the designer.
 *
 * A route handler rather than a server action returning bytes, because the
 * output IS the response: the browser can open it in a tab and the e2e
 * suite can assert on the bytes without a storage bucket in between. And
 * nothing is stored: a preview of a draft has no evidentiary value and
 * would only be a file to purge later. FR-T03 is where an issued
 * certificate gets persisted, hashed (FR-T09) and registered (FR-T08).
 *
 * The response carries the AC4 evidence in headers rather than only in
 * pixels: x-missing-glyph-count is the result of the cmap check run over
 * the exact strings that were about to be typeset, so "text does not fall
 * back to a boxed glyph" is a number the caller can read, not a judgement
 * about a rendering.
 */

const MIME_BY_EXT: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg', jpeg: 'image/jpeg' };

async function assetDataUri(
  supabase: Awaited<ReturnType<typeof supabaseServer>>,
  storagePath: string | null,
): Promise<string | null> {
  if (!storagePath) return null;
  const { data, error } = await supabase.storage.from('branding').download(storagePath);
  if (error || !data) return null;
  const mime = MIME_BY_EXT[storagePath.split('.').pop()?.toLowerCase() ?? ''] ?? 'image/png';
  return `data:${mime};base64,${Buffer.from(await data.arrayBuffer()).toString('base64')}`;
}

export async function GET(_request: NextRequest, { params }: { params: Promise<{ templateId: string }> }) {
  const { templateId } = await params;
  const supabase = await supabaseServer();

  const { data, error } = await supabase.rpc('certificate_preview_payload', { p_template_id: templateId });
  if (error || !data) {
    const status = error?.message.includes('FORBIDDEN') ? 403 : 404;
    return NextResponse.json({ error: 'Template not available.' }, { status });
  }
  const payload = data as unknown as CertificatePreviewPayload;

  const font = resolveNastaliqFont();
  const coverage = font
    ? checkGlyphCoverage(collectCertificateStrings(payload), parseCmapRanges(font.bytes))
    : { checkedCodepoints: 0, missing: [] };

  const doc = buildCertificateHtml(payload, font, {
    letterheadDataUri: await assetDataUri(supabase, payload.letterhead_storage_path),
    logoDataUri: await assetDataUri(supabase, payload.logo_storage_path),
  });

  let pdf: Buffer;
  try {
    pdf = await renderPdf(doc);
  } catch (cause) {
    const message = cause instanceof RendererUnavailableError ? 'No PDF renderer is available on this server.' : 'Could not render the certificate.';
    return NextResponse.json({ error: message }, { status: 503 });
  }

  return new NextResponse(new Uint8Array(pdf), {
    status: 200,
    headers: {
      'content-type': 'application/pdf',
      'content-disposition': `inline; filename="certificate-template-${templateId}.pdf"`,
      'cache-control': 'no-store',
      'x-missing-glyph-count': String(coverage.missing.length),
      'x-missing-glyphs': coverage.missing.join(','),
      'x-font-family': font ? NASTALIQ_FONT_FAMILY : '',
    },
  });
}
