/**
 * The house PDF seam. Established by FR-F15 (timetable print and export) as
 * lib/timetable-export/pdf.ts, moved here by FR-T01 (certificate template
 * designer) once a second, unrelated feature needed the same renderer and
 * the same Nastaliq machinery — the module was never timetable-specific,
 * only its address was. Callers own their own HTML; this owns the bytes.
 *
 * FR-F15: how a stored PDF file actually gets produced, and why this way.
 *
 * The ACs need real PDF bytes in a bucket behind a signed URL, so print
 * CSS alone (`@media print` + `@page`, no dependency at all) is not
 * sufficient on its own — it produces a correct printout but never a
 * stored file. Of the ways to produce the bytes:
 *
 *   * pdf-lib / @react-pdf/renderer / jsPDF draw text glyph-by-glyph from
 *     a font's cmap with no OpenType shaping. Nastaliq is almost entirely
 *     GSUB ligature substitution — Urdu rendered that way comes out as
 *     disconnected isolated forms, i.e. AC4 fails by construction. Each is
 *     also a new production dependency.
 *   * Headless Chromium shapes text with HarfBuzz, honours `@page { size:
 *     A4 portrait }` / `A3 landscape` natively, and subsets and embeds the
 *     Nastaliq face into the PDF it writes. Playwright already ships one
 *     for this repo's e2e suite, so this adds NO new package.
 *
 * Chromium therefore wins on correctness and on dependency weight at the
 * same time, and this module is deliberately the whole seam: FR-T09
 * (certificates) and FR-J09 (report cards) render their own HTML and call
 * renderPdf() — they will need the same Urdu shaping and the same paper
 * sizes.
 *
 * The honest caveat: @playwright/test is a devDependency. On this machine
 * (and in the e2e run) it is installed and its Chromium is downloaded, so
 * the export produces genuine PDF bytes. A production deployment has to
 * provide a Chromium — promoting the package, or pointing this module at a
 * remote browser — which is a deployment decision, not a code change. If
 * no browser can be launched the export fails loudly with
 * RENDERER_UNAVAILABLE and the job records it; it never silently returns
 * something that is not a PDF.
 */

/** Paper sizes any caller of this seam prints on, as CSS `@page size` names. */
export type PageFormat = 'A3' | 'A4' | 'A5' | 'Legal';

/**
 * A complete, self-contained print document: the HTML carries its own
 * `@page` rule and every asset inlined (fonts as data: URIs, images as
 * data: URIs), because the renderer loads it with setContent() and no
 * network. pageFormat/landscape restate what the stylesheet already says,
 * for callers that want to record or display it.
 */
export type PrintDocument = { html: string; pageFormat: PageFormat; landscape: boolean };

export class RendererUnavailableError extends Error {
  constructor(cause: unknown) {
    super('RENDERER_UNAVAILABLE');
    this.cause = cause;
  }
}

export async function renderPdf(doc: PrintDocument): Promise<Buffer> {
  let chromium: typeof import('@playwright/test').chromium;
  try {
    ({ chromium } = await import('@playwright/test'));
  } catch (cause) {
    throw new RendererUnavailableError(cause);
  }

  let browser;
  try {
    // ACADEMY_CHROMIUM_PATH lets a deployment (or a machine whose Playwright
    // build differs from its installed browser) point at the Chromium to use.
    browser = await chromium.launch({ executablePath: process.env.ACADEMY_CHROMIUM_PATH || undefined });
  } catch (cause) {
    throw new RendererUnavailableError(cause);
  }

  try {
    const page = await browser.newPage();
    await page.setContent(doc.html, { waitUntil: 'load' });
    // preferCSSPageSize makes the document's own `@page { size: ... }` rule
    // authoritative, so paper size lives in one place (the stylesheet) and
    // a screen preview of the same HTML paginates identically.
    return await page.pdf({ printBackground: true, preferCSSPageSize: true });
  } finally {
    await browser.close();
  }
}

/**
 * Page count read back off the produced bytes rather than assumed from the
 * sheet count — AC1/AC2 are about what the file actually contains. Skia
 * (Chromium's PDF writer) emits page objects uncompressed, so the page
 * tree is readable without a full PDF parser.
 */
export function pdfPageCount(bytes: Uint8Array): number {
  const text = Buffer.from(bytes).toString('latin1');
  const matches = text.match(/\/Type\s*\/Page(?![a-zA-Z])/g);
  return matches ? matches.length : 0;
}

/**
 * FR-J09. Rewrite the document's CreationDate/ModDate to a fixed instant.
 *
 * Two renders of one identical document differ in exactly two places —
 * Chromium writes wall-clock time into `/CreationDate` and `/ModDate` and
 * nothing else varies (verified byte-for-byte against Skia/PDF m151). That
 * is enough to make a report card's digest unreproducible, which would in
 * turn make the checksum on its register a statement about a moment rather
 * than about a document.
 *
 * Substitution is length-preserving, so every byte offset in the xref table
 * stays valid: `D:YYYYMMDDHHMMSS+00'00'` is a fixed 23 characters for any
 * date this function can be given. The length is re-checked anyway and a
 * mismatch leaves the bytes alone — a future renderer that writes a
 * different date format should cost reproducibility, never a corrupt file.
 */
export function stampPdfTimestamps(bytes: Uint8Array, at: Date): Uint8Array {
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  const stamp =
    `D:${p(at.getUTCFullYear(), 4)}${p(at.getUTCMonth() + 1)}${p(at.getUTCDate())}` +
    `${p(at.getUTCHours())}${p(at.getUTCMinutes())}${p(at.getUTCSeconds())}+00'00'`;

  const text = Buffer.from(bytes).toString('latin1');
  const rewritten = text.replace(/\/(CreationDate|ModDate) \(([^)]*)\)/g, (match, key: string, existing: string) =>
    existing.length === stamp.length ? `/${key} (${stamp})` : match,
  );
  return new Uint8Array(Buffer.from(rewritten, 'latin1'));
}

export function isPdf(bytes: Uint8Array): boolean {
  return Buffer.from(bytes.subarray(0, 5)).toString('latin1') === '%PDF-';
}

/** Every font BaseFont name embedded in the document, subset prefix stripped. */
export function embeddedFontNames(bytes: Uint8Array): string[] {
  const text = Buffer.from(bytes).toString('latin1');
  const names = new Set<string>();
  for (const match of text.matchAll(/\/BaseFont\s*\/([A-Za-z0-9+,.\-_]+)/g)) {
    names.add(match[1]!.replace(/^[A-Z]{6}\+/, ''));
  }
  return [...names];
}
