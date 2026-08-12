import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from './font';
import {
  SCHOOL_WEEKDAYS,
  buildMasterPages,
  buildSectionSheets,
  buildTeacherSheets,
  formatPeriodTime,
  masterGridMetrics,
  resolvePeriods,
  sheetGridMetrics,
  weekdayLabel,
  type ExportPayload,
  type PayloadSection,
  type PayloadSlot,
  type Sheet,
} from './layout';

export type PrintDocument = { html: string; pageFormat: 'A4' | 'A3'; landscape: boolean };

const LAYOUT_TITLE = {
  section: 'Section timetable',
  teacher: 'Teacher timetable',
  master: 'Master grid',
} as const;

function esc(value: string | null | undefined): string {
  if (value === null || value === undefined) return '';
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function headerHtml(payload: ExportPayload, logoDataUri: string | null, pageTitle: string, pageSubtitle: string): string {
  const { tenant, campus, session, version } = payload;
  const effective = version.effective_from
    ? `Effective ${version.effective_from}${version.effective_to ? ` – ${version.effective_to}` : ''}`
    : 'Not yet published';
  return `<header class="sheet-header">
  ${logoDataUri ? `<img class="logo" src="${logoDataUri}" alt="" />` : '<div class="logo logo-empty"></div>'}
  <div class="identity">
    <div class="school">${esc(tenant.name)}${tenant.name_ur ? ` <span class="ur">${esc(tenant.name_ur)}</span>` : ''}</div>
    <div class="meta">${esc(campus.name)} (${esc(campus.code)}) · Session ${esc(session.name)} · ${esc(version.shift)}</div>
    <div class="meta">Timetable version ${version.version_no} — ${esc(version.status)} · ${esc(effective)}</div>
  </div>
  <div class="sheet-title">
    <div class="title">${esc(pageTitle)}</div>
    <div class="subtitle">${esc(pageSubtitle)}</div>
  </div>
</header>`;
}

function subjectCellHtml(slot: PayloadSlot, section: PayloadSection | undefined, secondLine: string): string {
  // AC4: on an Urdu-medium section the Urdu name is the primary line, with
  // the English name kept underneath so a bilingual staff room can read
  // either. On an English-medium section it is the other way round — the
  // Urdu name still prints, which is what makes the glyph check meaningful
  // on every sheet rather than only on Urdu-medium campuses.
  const urduFirst = section?.medium === 'URDU';
  const urdu = `<span class="ur">${esc(slot.subject_name_ur)}</span>`;
  const english = `<span class="en">${esc(slot.subject_name_en)}</span>`;
  return `<div class="subject">${urduFirst ? urdu : english}</div>
<div class="subject-alt">${urduFirst ? english : urdu}</div>
${secondLine ? `<div class="detail">${esc(secondLine)}</div>` : ''}`;
}

function sheetHtml(payload: ExportPayload, sheet: Sheet, logoDataUri: string | null, mode: 'section' | 'teacher'): string {
  const sectionById = new Map(payload.sections.map((s) => [s.id, s]));
  const rows = sheet.rows
    .map((row) => {
      const cells = row.cells
        .map((slot) => {
          if (!slot) return '<td class="free">Free</td>';
          const section = sectionById.get(slot.section_id);
          const detail =
            mode === 'section'
              ? [slot.teacher_name, slot.room_code].filter(Boolean).join(' · ')
              : [section ? `${section.class_level_name_en} ${section.name}` : null, slot.room_code].filter(Boolean).join(' · ');
          return `<td>${subjectCellHtml(slot, section, detail)}</td>`;
        })
        .join('');
      const time = formatPeriodTime(row.period);
      return `<tr><th class="period"><span class="no">${row.period.period_no}</span>${time ? `<span class="time">${esc(time)}</span>` : ''}</th>${cells}</tr>`;
    })
    .join('');

  return `<section class="sheet">
${headerHtml(payload, logoDataUri, sheet.title, sheet.subtitle)}
<table class="grid">
  <thead><tr><th class="period">Period</th>${SCHOOL_WEEKDAYS.map((w) => `<th>${esc(weekdayLabel(w))}</th>`).join('')}</tr></thead>
  <tbody>${rows}</tbody>
</table>
</section>`;
}

function masterPageHtml(payload: ExportPayload, page: ReturnType<typeof buildMasterPages>[number], logoDataUri: string | null): string {
  const rows = page.rows
    .map((row) => {
      const cells = row.cells
        .map((slot) => {
          if (!slot) return '<td class="free">—</td>';
          return `<td><span class="code">${esc(slot.subject_code)}</span>${slot.room_code ? `<span class="room">${esc(slot.room_code)}</span>` : ''}</td>`;
        })
        .join('');
      return `<tr><th class="section-name">${esc(row.label)}</th>${cells}</tr>`;
    })
    .join('');

  return `<section class="sheet">
${headerHtml(payload, logoDataUri, `Master grid — ${page.title}`, `${page.rows.length} sections × ${page.periodNumbers.length} periods`)}
<table class="grid master">
  <thead><tr><th class="section-name">Section</th>${page.periodNumbers.map((p) => `<th>P${p}</th>`).join('')}</tr></thead>
  <tbody>${rows}</tbody>
</table>
</section>`;
}

function css(payload: ExportPayload, font: ResolvedFont | null): string {
  const isMaster = payload.job.layout === 'master';
  const metrics = isMaster
    ? masterGridMetrics(payload.sections.length)
    : sheetGridMetrics(resolvePeriods(payload).length);

  return `${nastaliqFontFaceCss(font)}
@page { size: ${isMaster ? 'A3 landscape' : 'A4 portrait'}; margin: ${isMaster ? '10mm' : '12mm'}; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; color: #111; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.sheet { break-after: page; page-break-after: always; }
.sheet:last-child { break-after: auto; page-break-after: auto; }
.sheet-header { display: flex; align-items: center; gap: 6mm; border-bottom: 0.6mm solid #111; padding-bottom: 2mm; margin-bottom: 3mm; }
.logo { width: 16mm; height: 16mm; object-fit: contain; }
.logo-empty { border: 0.2mm dashed #bbb; }
.identity { flex: 1 1 auto; }
.school { font-size: 13pt; font-weight: 700; }
.meta { font-size: 8pt; color: #333; }
.sheet-title { text-align: right; }
.sheet-title .title { font-size: 12pt; font-weight: 700; }
.sheet-title .subtitle { font-size: 8pt; color: #333; }
.grid { width: 100%; border-collapse: collapse; table-layout: fixed; font-size: ${metrics.fontPt}pt; }
.grid th, .grid td { border: 0.2mm solid #999; padding: 0.6mm 1mm; vertical-align: top; overflow-wrap: anywhere; word-break: break-word; }
.grid thead th { background: #eee; font-weight: 700; text-align: center; }
.grid tbody tr { height: ${metrics.rowHeightMm.toFixed(2)}mm; }
.grid th.period { width: 16mm; text-align: center; background: #f5f5f5; }
.grid th.period .no { display: block; font-weight: 700; }
.grid th.period .time { display: block; font-size: 0.8em; color: #444; font-weight: 400; }
.grid td.free { color: #999; text-align: center; }
.subject { font-weight: 700; line-height: 1.15; }
.subject-alt { color: #444; line-height: 1.15; }
.detail { color: #444; line-height: 1.15; }
.ur { font-family: '${NASTALIQ_FONT_FAMILY}', serif; direction: rtl; unicode-bidi: isolate; line-height: 1.9; }
.master th.section-name { width: 34mm; text-align: left; background: #f5f5f5; font-weight: 700; }
.master td { text-align: center; }
.master .code { display: block; font-weight: 700; line-height: 1.15; }
.master .room { display: block; color: #444; line-height: 1.15; }`;
}

export function buildExportHtml(payload: ExportPayload, font: ResolvedFont | null, logoDataUri: string | null): PrintDocument {
  const layout = payload.job.layout;
  let body: string;
  if (layout === 'master') {
    body = buildMasterPages(payload)
      .map((page) => masterPageHtml(payload, page, logoDataUri))
      .join('\n');
  } else if (layout === 'teacher') {
    body = buildTeacherSheets(payload)
      .map((sheet) => sheetHtml(payload, sheet, logoDataUri, 'teacher'))
      .join('\n');
  } else {
    body = buildSectionSheets(payload)
      .map((sheet) => sheetHtml(payload, sheet, logoDataUri, 'section'))
      .join('\n');
  }

  if (!body) {
    body = `<section class="sheet">${headerHtml(payload, logoDataUri, LAYOUT_TITLE[layout], 'Nothing to print')}<p>This timetable version has no scheduled periods in scope.</p></section>`;
  }

  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${esc(LAYOUT_TITLE[layout])} — ${esc(payload.campus.name)}</title><style>${css(payload, font)}</style></head><body>${body}</body></html>`;
  return { html, pageFormat: layout === 'master' ? 'A3' : 'A4', landscape: layout === 'master' };
}
