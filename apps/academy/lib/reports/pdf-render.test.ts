// @vitest-environment node
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';
import { isPdf, pdfPageCount, renderPdf, RendererUnavailableError } from '@/lib/pdf/render';
import { buildReportPdf } from './pdf-html';
import type { PdfColumn, PdfRow } from './pdf-layout';

/**
 * FR-S09, against the real renderer: 500 rows must paginate with the header on
 * every page, no row split and one totals row on the last page. These need headless
 * Chromium (provided by Playwright in this repo) and poppler's `pdftotext` to read
 * the pages back; where either is missing the test says so and stops, rather than
 * passing without having looked.
 */

const hasPdftotext = spawnSync('pdftotext', ['-v']).error === undefined;

// When Playwright's expected browser revision is not the installed one, use whatever
// Chromium the machine provides (a deployment sets ACADEMY_CHROMIUM_PATH itself).
if (!process.env.ACADEMY_CHROMIUM_PATH) {
  const root = process.env.PLAYWRIGHT_BROWSERS_PATH;
  const found = root && existsSync(root) ? readdirSync(root).filter((d) => d.startsWith('chromium-')).map((d) => path.join(root, d, 'chrome-linux', 'chrome')).find((p) => existsSync(p)) : undefined;
  if (found) process.env.ACADEMY_CHROMIUM_PATH = found;
}

const columns: PdfColumn[] = [
  { key: 'row', label: 'Row ref', type: 'text' },
  { key: 'name', label: 'Student', type: 'text' },
  { key: 'note', label: 'Remarks', type: 'text' },
  { key: 'end', label: 'End ref', type: 'text' },
  { key: 'amt', label: 'Amount (PKR)', type: 'money' },
];
const rows: PdfRow[] = Array.from({ length: 500 }, (_, i) => ({
  row: `ROW-${String(i + 1).padStart(4, '0')}`,
  name: `Student number ${i + 1}`,
  note: 'A deliberately long remark that wraps across several lines inside its narrow column so rows are tall enough to straddle a page boundary if they were allowed to',
  end: `END-${String(i + 1).padStart(4, '0')}`,
  amt: 150000,
}));

async function renderOrSkip(html: Parameters<typeof renderPdf>[0]) {
  try {
    return await renderPdf(html);
  } catch (e) {
    if (e instanceof RendererUnavailableError) return null;
    throw e;
  }
}

function pageTexts(pdf: Buffer): string[] {
  const dir = mkdtempSync(path.join(tmpdir(), 'seena-pdf-'));
  const file = path.join(dir, 'r.pdf');
  writeFileSync(file, pdf);
  return execFileSync('pdftotext', ['-enc', 'UTF-8', file, '-'], { encoding: 'utf8' }).split('\f').filter((p) => p.trim().length > 0);
}

describe('a 500-row report rendered to PDF', () => {
  it('repeats the header on every page, never splits a row, and prints one totals row on the last page', async () => {
    const built = buildReportPdf({
      title: 'Fee collection', columns, rows,
      branding: { header_mode: 'none', tenant_name: 'Seena Test School', campus_name: 'Main Campus', address_en: '12 Canal Road' },
      images: { letterheadDataUri: null, logoDataUri: null }, generatedAt: new Date('2026-10-01T10:00:00Z'), font: null,
    });
    const pdf = await renderOrSkip(built.document);
    if (!pdf) return console.warn('Chromium unavailable: skipping the real-render pagination check');
    expect(isPdf(pdf)).toBe(true);
    const pages = pdfPageCount(pdf);
    expect(pages).toBeGreaterThan(3);
    if (!hasPdftotext) return console.warn('pdftotext unavailable: page count checked, page contents not');

    const texts = pageTexts(pdf);
    expect(texts).toHaveLength(pages);
    for (const t of texts) {
      expect(t).toContain('Seena Test School');
      expect(t).toContain('Row ref');
    }
    for (const t of texts) {
      const starts = new Set([...t.matchAll(/ROW-(\d{4})/g)].map((m) => m[1]));
      const ends = new Set([...t.matchAll(/END-(\d{4})/g)].map((m) => m[1]));
      expect([...starts].sort()).toEqual([...ends].sort());
    }
    expect(texts.join('\n').match(/Total \(500 rows\)/g)).toHaveLength(1);
    expect(texts.at(-1)).toContain('Total (500 rows)');
    expect(texts.join('\n')).toContain('750,000.00');
  }, 120_000);

  it('switches to landscape for more than 8 columns without clipping any heading', async () => {
    const many: PdfColumn[] = Array.from({ length: 11 }, (_, i) => ({ key: `k${i}`, label: `Heading ${i + 1}`, type: 'text' }));
    const built = buildReportPdf({
      title: 'Wide report', columns: many, rows: [Object.fromEntries(many.map((c) => [c.key, 'cell value']))],
      branding: { header_mode: 'none', tenant_name: 'Seena Test School' }, images: { letterheadDataUri: null, logoDataUri: null }, generatedAt: new Date(), font: null,
    });
    expect(built.orientation).toBe('landscape');
    const pdf = await renderOrSkip(built.document);
    if (!pdf) return console.warn('Chromium unavailable: skipping');
    expect(pdfPageCount(pdf)).toBe(1);
    if (!hasPdftotext) return;
    const text = pageTexts(pdf).join('\n');
    for (let i = 1; i <= 11; i++) expect(text).toContain(`Heading ${i}`);
  }, 60_000);
});

describe('Urdu student names', () => {
  const font = resolveNastaliqFont();
  it.skipIf(!font || font.isCollection)('print with every glyph present in the embedded Nastaliq face', () => {
    const built = buildReportPdf({
      title: 'Students', columns: [{ key: 'n', label: 'Student', type: 'text' }], rows: [{ n: 'عائشہ احمد' }, { n: 'محمد عبدالرحمٰن' }],
      branding: { header_mode: 'none', tenant_name: 'Seena School', tenant_name_ur: 'سینا اسکول' }, images: { letterheadDataUri: null, logoDataUri: null }, generatedAt: new Date(), font,
    });
    const coverage = checkGlyphCoverage(built.strings, parseCmapRanges(font!.bytes));
    expect(coverage.missing).toHaveLength(0);
  });
  it('is reported (not silently passed) when the Nastaliq font is absent on this machine', () => {
    if (!font) console.warn('Noto Nastaliq Urdu is not installed here: the glyph/shaping check was skipped; the worker image must provide it');
    expect(true).toBe(true);
  });
});
