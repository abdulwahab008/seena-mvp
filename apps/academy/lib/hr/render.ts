import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont, type ResolvedFont } from '@/lib/pdf/font';
import { renderPdf, stampPdfTimestamps, isPdf, type PrintDocument } from '@/lib/pdf/render';

/** The embedded Urdu face cannot draw some character in the document. A tofu box on a school letterhead is not acceptable. */
export class MissingGlyphsError extends Error {
  constructor(public readonly missing: string[]) {
    super('MISSING_GLYPHS');
  }
}

/**
 * FR-D17 / FR-D18: render a Staff & HR document to PDF bytes.
 *
 * The Urdu font is resolved first and every Arabic-script character about to be printed is looked up
 * in its cmap BEFORE rendering (same check FR-F15/FR-T01 use), so a missing glyph fails loudly
 * instead of printing a box. The PDF's creation/modification dates are pinned to `stampAt` (the
 * moment the business record was approved or issued), which makes re-rendering the same record
 * reproduce the same bytes.
 *
 * Throws RendererUnavailableError (no Chromium on this host) or MissingGlyphsError.
 */
export async function renderHrPdf(build: (font: ResolvedFont | null) => PrintDocument, strings: readonly string[], stampAt: Date): Promise<Uint8Array> {
  const font = resolveNastaliqFont();
  if (font && !font.isCollection) {
    const coverage = checkGlyphCoverage(strings, parseCmapRanges(font.bytes));
    if (coverage.missing.length > 0) throw new MissingGlyphsError(coverage.missing);
  }
  const bytes = await renderPdf(build(font));
  const stamped = stampPdfTimestamps(new Uint8Array(bytes), stampAt);
  if (!isPdf(stamped)) throw new Error('RENDER_FAILED');
  return stamped;
}
