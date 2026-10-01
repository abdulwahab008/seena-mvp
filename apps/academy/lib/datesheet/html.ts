import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';

/**
 * FR-I04 AC4: the datesheet PDF names every subject in English AND Urdu, with
 * the Nastaliq face embedded (see lib/pdf/font.ts for how the face is resolved
 * and verified glyph by glyph before the page is typeset). Revised versions
 * carry a banner and highlight the rows that are new or moved against the
 * previous version.
 */
export type DatesheetPdfRow = {
  class_name: string;
  subject_name_en: string;
  subject_name_ur: string | null;
  start_at: string;
  end_at: string;
  hall_name: string | null;
  change_kind: 'new' | 'moved' | 'unchanged';
  previous_start_at: string | null;
};

export type DatesheetPdfPayload = {
  campusName: string;
  title: string;
  versionNo: number;
  publishedAt: string;
  note: string | null;
  timezone: string;
  rows: DatesheetPdfRow[];
};

function esc(value: string | null | undefined): string {
  if (value === null || value === undefined) return '';
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const dateOf = (iso: string, tz: string) => new Date(iso).toLocaleDateString('en-GB', { timeZone: tz, weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
const timeOf = (iso: string, tz: string) => new Date(iso).toLocaleTimeString('en-GB', { timeZone: tz, hour: '2-digit', minute: '2-digit' });

/** Every string that is about to be typeset, for the glyph coverage check. */
export function collectDatesheetStrings(payload: DatesheetPdfPayload): (string | null)[] {
  return [payload.title, payload.campusName, ...payload.rows.flatMap((r): (string | null)[] => [r.subject_name_ur, r.subject_name_en])];
}

export function isRevised(payload: DatesheetPdfPayload): boolean {
  return payload.versionNo > 1;
}

export function buildDatesheetHtml(payload: DatesheetPdfPayload, font: ResolvedFont | null): PrintDocument {
  const tz = payload.timezone;
  const revised = isRevised(payload);
  const classes = [...new Set(payload.rows.map((r) => r.class_name))].sort((a, b) => a.localeCompare(b, 'en', { numeric: true }));
  const sections = classes
    .map((className) => {
      const rows = payload.rows
        .filter((r) => r.class_name === className)
        .sort((a, b) => a.start_at.localeCompare(b.start_at))
        .map((r) => {
          const changed = revised && r.change_kind !== 'unchanged';
          const moved = changed && r.previous_start_at ? `<div class="was">was ${esc(dateOf(r.previous_start_at, tz))}</div>` : '';
          return `<tr class="${changed ? 'changed' : ''}">
  <td>${esc(dateOf(r.start_at, tz))}${moved}</td>
  <td>${esc(timeOf(r.start_at, tz))} – ${esc(timeOf(r.end_at, tz))}</td>
  <td><span class="en">${esc(r.subject_name_en)}</span><span class="ur">${esc(r.subject_name_ur)}</span></td>
  <td>${esc(r.hall_name) || '—'}</td>
  <td class="flag">${changed ? (r.change_kind === 'new' ? 'NEW' : 'CHANGED') : ''}</td>
</tr>`;
        })
        .join('');
      return `<section class="class">
<h2>${esc(className)}</h2>
<table><thead><tr><th>Date</th><th>Time</th><th>Subject</th><th>Hall</th><th></th></tr></thead><tbody>${rows}</tbody></table>
</section>`;
    })
    .join('\n');

  const banner = revised
    ? `<div class="banner" data-revised="true">REVISED — version ${payload.versionNo}, published ${esc(dateOf(payload.publishedAt, tz))}.${payload.note ? ` ${esc(payload.note)}` : ''} Changed papers are highlighted.</div>`
    : '';

  const css = `${nastaliqFontFaceCss(font)}
@page { size: A4 portrait; margin: 12mm; }
* { box-sizing: border-box; }
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; color: #111; font-size: 10pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
header { border-bottom: 0.6mm solid #111; padding-bottom: 2mm; margin-bottom: 4mm; }
header .school { font-size: 14pt; font-weight: 700; }
header .meta { font-size: 9pt; color: #333; }
.banner { background: #fde68a; border: 0.3mm solid #b45309; padding: 2mm 3mm; margin-bottom: 4mm; font-weight: 700; }
.class { break-inside: avoid; margin-bottom: 6mm; }
h2 { font-size: 11pt; margin: 0 0 2mm; }
table { width: 100%; border-collapse: collapse; }
th, td { border: 0.2mm solid #999; padding: 1.2mm 2mm; text-align: left; vertical-align: top; }
thead th { background: #eee; }
tr.changed td { background: #fef3c7; }
.flag { font-weight: 700; color: #92400e; width: 18mm; }
.was { font-size: 8pt; color: #666; }
.en { display: block; font-weight: 700; }
.ur { display: block; font-family: '${NASTALIQ_FONT_FAMILY}', serif; direction: rtl; unicode-bidi: isolate; line-height: 1.9; }`;

  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${esc(payload.title)} v${payload.versionNo}</title><style>${css}</style></head><body>
<header><div class="school">${esc(payload.campusName)}</div><div class="meta">${esc(payload.title)} · version ${payload.versionNo} · published ${esc(dateOf(payload.publishedAt, tz))}</div></header>
${banner}
${sections || '<p>No papers are scheduled.</p>'}
</body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}
