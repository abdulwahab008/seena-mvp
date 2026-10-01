import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';
import { escapeHtml } from '@/lib/certificates/merge';

/**
 * The shared shell for Staff & HR documents (final settlement statement, experience and
 * service certificates): an A4 page, a letterhead carrying the school name in English and,
 * when the school has one, in Urdu set in the embedded Nastaliq face, and a body the caller
 * builds. Same renderer seam (lib/pdf/render.ts) and the same font machinery the
 * timetable and certificate PDFs use; the page is self-contained (fonts and images inlined)
 * because it is rendered without a network.
 */
export type HrDocumentInput = {
  title: string;
  schoolName: string;
  schoolNameUr: string | null;
  place?: string | null;
  /** Already-escaped HTML. Callers escape every dynamic value with escapeHtml(). */
  bodyHtml: string;
  footerHtml?: string;
  letterheadDataUri?: string | null;
  /** 'ur' sets the whole body right-to-left in Nastaliq. */
  language?: 'en' | 'ur';
};

export function collectHrDocumentStrings(doc: HrDocumentInput): string[] {
  return [doc.title, doc.schoolName, doc.schoolNameUr ?? '', doc.place ?? '', doc.bodyHtml.replace(/<[^>]*>/g, ' '), doc.footerHtml?.replace(/<[^>]*>/g, ' ') ?? ''];
}

function css(font: ResolvedFont | null, rtl: boolean): string {
  const bodyFont = rtl ? `'${NASTALIQ_FONT_FAMILY}', 'Noto Naskh Arabic', serif` : `'Times New Roman', Times, Georgia, serif`;
  return `${nastaliqFontFaceCss(font)}
@page { size: A4 portrait; margin: 16mm 18mm; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: ${bodyFont}; font-size: ${rtl ? '13pt' : '11.5pt'}; line-height: ${rtl ? '2.4' : '1.6'}; color: #111; direction: ${rtl ? 'rtl' : 'ltr'}; text-align: ${rtl ? 'right' : 'left'}; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.letterhead { text-align: center; border-bottom: 0.6mm solid #111; padding-bottom: 4mm; margin-bottom: 6mm; }
.letterhead img { max-width: 100%; }
.letterhead .school { font-size: 18pt; font-weight: 700; line-height: 1.5; }
.letterhead .school-ur { font-family: '${NASTALIQ_FONT_FAMILY}', 'Noto Naskh Arabic', serif; direction: rtl; font-size: 17pt; line-height: 2.2; }
.letterhead .place { font-size: 10pt; color: #333; }
.doc-title { text-align: center; font-size: 14pt; font-weight: 700; letter-spacing: 0.3mm; margin: 0 0 6mm; text-decoration: underline; }
table.lines { width: 100%; border-collapse: collapse; margin: 4mm 0; }
table.lines th, table.lines td { border: 0.2mm solid #666; padding: 1.6mm 2.2mm; text-align: left; vertical-align: top; }
table.lines td.num, table.lines th.num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
table.lines tr.total td { font-weight: 700; border-top: 0.5mm solid #111; }
.meta { width: 100%; margin-bottom: 4mm; font-size: 10.5pt; }
.meta td { padding: 0.6mm 0; }
.signatures { margin-top: 22mm; display: flex; justify-content: space-between; gap: 10mm; }
.signatures div { flex: 1 1 0; border-top: 0.3mm solid #111; padding-top: 2mm; font-size: 10pt; text-align: center; }
.footer { margin-top: 8mm; font-size: 9pt; color: #444; }`;
}

export function buildHrDocumentHtml(doc: HrDocumentInput, font: ResolvedFont | null): PrintDocument {
  const rtl = doc.language === 'ur';
  const letterhead = doc.letterheadDataUri
    ? `<div class="letterhead"><img src="${doc.letterheadDataUri}" alt="" /></div>`
    : `<div class="letterhead">
  <div class="school">${escapeHtml(doc.schoolName)}</div>
  ${doc.schoolNameUr ? `<div class="school-ur" lang="ur" dir="rtl">${escapeHtml(doc.schoolNameUr)}</div>` : ''}
  ${doc.place ? `<div class="place">${escapeHtml(doc.place)}</div>` : ''}
</div>`;
  const html = `<!doctype html><html lang="${rtl ? 'ur' : 'en'}" dir="${rtl ? 'rtl' : 'ltr'}"><head><meta charset="utf-8"><title>${escapeHtml(doc.title)}</title><style>${css(font, rtl)}</style></head><body>
${letterhead}
<h1 class="doc-title">${escapeHtml(doc.title)}</h1>
${doc.bodyHtml}
${doc.footerHtml ? `<div class="footer">${doc.footerHtml}</div>` : ''}
</body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}
