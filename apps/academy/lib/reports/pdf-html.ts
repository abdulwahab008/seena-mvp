import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';
import {
  cellText,
  distributeColumnWidths,
  hasUrdu,
  orientationFor,
  totalsRow,
  usableWidthMm,
  type ColumnLayout,
  type Orientation,
  type PdfColumn,
  type PdfRow,
} from './pdf-layout';

/**
 * FR-S09: a report as a printable document on campus letterhead. One <table>
 * whose <thead> carries the identity block AND the column headings, so the browser
 * repeats both on every page; rows are `break-inside: avoid`, so a row never
 * splits; the totals row is the last row of <tbody>, so it appears once, on the
 * final page. (A <tfoot> would repeat on every page.)
 */

export type ReportBranding = {
  header_mode: 'letterhead' | 'logo' | 'none';
  tenant_name: string;
  tenant_name_ur?: string | null;
  campus_name?: string | null;
  campus_name_ur?: string | null;
  address_en?: string | null;
  address_ur?: string | null;
};

export type BrandingImages = { letterheadDataUri: string | null; logoDataUri: string | null };

export type ReportPdfInput = {
  title: string;
  columns: PdfColumn[];
  rows: PdfRow[];
  branding: ReportBranding;
  images: BrandingImages;
  filters?: Record<string, unknown>;
  requestedBy?: string;
  generatedAt: Date;
  font: ResolvedFont | null;
};

export type ReportPdf = { document: PrintDocument; orientation: Orientation; layout: ColumnLayout; strings: string[] };

export function esc(value: string | null | undefined): string {
  if (value === null || value === undefined) return '';
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

/** Urdu runs are marked so the shaper and the bidi algorithm treat them as right-to-left Nastaliq. */
export function textHtml(text: string): string {
  return hasUrdu(text) ? `<span class="ur" dir="rtl" lang="ur">${esc(text)}</span>` : esc(text);
}

function filterSummary(filters: Record<string, unknown> | undefined): string {
  const entries = Object.entries(filters ?? {}).filter(([, v]) => v !== null && v !== undefined && v !== '');
  return entries.length === 0 ? 'No filters' : entries.map(([k, v]) => `${k.replace(/_/g, ' ')}: ${String(v)}`).join(' · ');
}

function identityHtml(b: ReportBranding, images: BrandingImages, columnCount: number): string {
  const names = `<div class="school">${textHtml(b.tenant_name)}${b.tenant_name_ur ? ` ${textHtml(b.tenant_name_ur)}` : ''}</div>
    <div class="campus">${b.campus_name ? textHtml(b.campus_name) : ''}${b.campus_name_ur ? ` ${textHtml(b.campus_name_ur)}` : ''}</div>
    <div class="address">${b.address_en ? esc(b.address_en) : ''}${b.address_ur ? ` ${textHtml(b.address_ur)}` : ''}</div>`;
  let inner: string;
  if (b.header_mode === 'letterhead' && images.letterheadDataUri) {
    inner = `<img class="letterhead" src="${images.letterheadDataUri}" alt="" />`;
  } else if (images.logoDataUri) {
    // no campus letterhead: the logo stands in and the layout keeps its shape
    inner = `<div class="id-row"><img class="logo" src="${images.logoDataUri}" alt="" /><div class="identity">${names}</div></div>`;
  } else {
    inner = `<div class="id-row"><div class="logo logo-empty"></div><div class="identity">${names}</div></div>`;
  }
  return `<tr class="identity-row"><td colspan="${columnCount}">${inner}</td></tr>`;
}

export function reportStrings(input: ReportPdfInput): string[] {
  const { branding: b } = input;
  return [
    input.title,
    ...input.columns.map((c) => c.label),
    ...input.rows.flatMap((r) => input.columns.map((c) => cellText(c, r[c.key]))),
    b.tenant_name, b.tenant_name_ur ?? '', b.campus_name ?? '', b.campus_name_ur ?? '', b.address_en ?? '', b.address_ur ?? '',
  ].filter((s) => s.length > 0);
}

export function buildReportPdf(input: ReportPdfInput): ReportPdf {
  const orientation = orientationFor(input.columns.length);
  const layout = distributeColumnWidths(input.columns, input.rows, usableWidthMm(orientation));
  const totals = totalsRow(input.columns, input.rows);
  const n = input.columns.length;

  const colgroup = `<colgroup>${layout.widthsMm.map((w) => `<col style="width:${w}mm" />`).join('')}</colgroup>`;
  const head = `<thead>
${identityHtml(input.branding, input.images, n)}
<tr class="title-row"><td colspan="${n}"><div class="title">${textHtml(input.title)}</div>
<div class="meta">${esc(filterSummary(input.filters))} · Generated ${esc(input.generatedAt.toLocaleString('en-PK', { timeZone: 'Asia/Karachi' }))}${input.requestedBy ? ` by ${textHtml(input.requestedBy)}` : ''}</div></td></tr>
<tr class="cols">${input.columns.map((c) => `<th class="${c.type === 'money' || c.type === 'int' ? 'num' : ''}">${textHtml(c.label)}</th>`).join('')}</tr>
</thead>`;
  const body = input.rows
    .map((r) => `<tr>${input.columns.map((c) => `<td class="${c.type === 'money' || c.type === 'int' ? 'num' : ''}">${textHtml(cellText(c, r[c.key]))}</td>`).join('')}</tr>`)
    .join('\n');
  // The label spans every column before the first money column so "Total (500 rows)" never wraps inside a narrow first column.
  const firstMoney = Math.max(input.columns.findIndex((c) => c.type === 'money'), 1);
  const totalsHtml = totals
    ? `<tr class="totals"><td colspan="${firstMoney}">${esc(totals.label)}</td>${input.columns
        .slice(firstMoney)
        .map((c) => `<td class="${c.type === 'money' ? 'num' : ''}">${esc(totals.cells[c.key] ?? '')}</td>`)
        .join('')}</tr>`
    : '';

  const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8" /><title>${esc(input.title)}</title>
<style>
${nastaliqFontFaceCss(input.font)}
@page { size: A4 ${orientation}; margin: 10mm; @bottom-right { content: "Page " counter(page) " of " counter(pages); font: 7pt sans-serif; color: #555; } }
* { box-sizing: border-box; }
body { margin: 0; font-family: 'Helvetica Neue', Arial, sans-serif; font-size: ${layout.fontPt}pt; color: #111; }
.ur { font-family: '${NASTALIQ_FONT_FAMILY}', serif; line-height: 2; unicode-bidi: isolate; }
table { width: 100%; border-collapse: collapse; table-layout: fixed; }
thead { display: table-header-group; }
tr { break-inside: avoid; page-break-inside: avoid; }
td, th { padding: 1.2mm 1.5mm; border-bottom: 0.2mm solid #ccc; vertical-align: top; text-align: left; overflow-wrap: break-word; word-break: normal; }
th { background: #f0f0f0; font-weight: 600; border-bottom: 0.4mm solid #444; }
.num { text-align: right; font-variant-numeric: tabular-nums; }
.identity-row td, .title-row td { border: 0; padding: 0 0 2mm 0; }
.letterhead { display: block; width: 100%; max-height: 32mm; object-fit: contain; }
.id-row { display: flex; align-items: center; gap: 4mm; }
.logo { width: 20mm; height: 20mm; object-fit: contain; }
.logo-empty { background: transparent; }
.school { font-size: ${layout.fontPt + 5}pt; font-weight: 700; }
.campus { font-size: ${layout.fontPt + 1.5}pt; }
.address, .meta { color: #444; font-size: ${Math.max(layout.fontPt - 1.5, 6)}pt; }
.title { font-size: ${layout.fontPt + 3}pt; font-weight: 700; margin-top: 1mm; }
tr.totals td { font-weight: 700; border-top: 0.5mm solid #111; border-bottom: 0; background: #fafafa; }
</style></head>
<body>
<table data-report-orientation="${orientation}">
${colgroup}
${head}
<tbody>
${body}
${totalsHtml}
</tbody>
</table>
</body></html>`;

  return { document: { html, pageFormat: 'A4', landscape: orientation === 'landscape' }, orientation, layout, strings: reportStrings(input) };
}
