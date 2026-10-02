import { NASTALIQ_FONT_FAMILY, nastaliqFontFaceCss, type ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';

/**
 * FR-I09: the seating chart (a hall map for the invigilators and the door) and
 * the seat slips (one per candidate, each printing the paper-set letter of the
 * seat it is for). Both come from fn_seating_chart(), so what is printed is
 * exactly what the database allocated.
 */
export type SeatAllocation = {
  row_no: number;
  seat_no: number;
  label: string;
  set_code: string;
  gr_number: string;
  name_en: string;
  name_ur: string | null;
  section_name: string;
  section_id: string;
  roll_no: number | null;
};

export type SeatingChart = {
  slot_id: string;
  start_at: string;
  end_at: string;
  class_name: string;
  subject_name_en: string;
  subject_name_ur: string | null;
  hall: { id: string; name: string; code: string; rows: number; seats_per_row: number } | null;
  set_count: number;
  timezone: string;
  allocations: SeatAllocation[];
};

function esc(value: string | null | undefined): string {
  if (value === null || value === undefined) return '';
  return value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

const when = (chart: SeatingChart) => {
  const d = new Date(chart.start_at).toLocaleDateString('en-GB', { timeZone: chart.timezone, weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
  const t = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { timeZone: chart.timezone, hour: '2-digit', minute: '2-digit' });
  return `${d}, ${t(chart.start_at)} – ${t(chart.end_at)}`;
};

export function collectSeatingStrings(chart: SeatingChart): (string | null)[] {
  return [chart.subject_name_ur, chart.subject_name_en, ...chart.allocations.flatMap((a): (string | null)[] => [a.name_ur, a.name_en])];
}

const baseCss = (font: ResolvedFont | null) => `${nastaliqFontFaceCss(font)}
* { box-sizing: border-box; }
body { font-family: 'Helvetica Neue', Helvetica, Arial, sans-serif; color: #111; font-size: 9pt; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
.ur { font-family: '${NASTALIQ_FONT_FAMILY}', serif; direction: rtl; unicode-bidi: isolate; line-height: 1.9; }`;

export function buildSeatingChartHtml(chart: SeatingChart, font: ResolvedFont | null): PrintDocument {
  const hall = chart.hall;
  const bySeat = new Map(chart.allocations.map((a) => [`${a.row_no}:${a.seat_no}`, a]));
  const sectionIds = [...new Set(chart.allocations.map((a) => a.section_id))];
  const palette = ['#dbeafe', '#dcfce7', '#fee2e2', '#fef9c3', '#ede9fe', '#ffedd5'];
  const colour = new Map(sectionIds.map((id, i) => [id, palette[i % palette.length]!]));
  let grid = '<p>No hall is assigned to this paper.</p>';
  if (hall) {
    const rows: string[] = [];
    for (let r = 1; r <= hall.rows; r += 1) {
      const cells: string[] = [];
      for (let s = 1; s <= hall.seats_per_row; s += 1) {
        const a = bySeat.get(`${r}:${s}`);
        cells.push(
          a
            ? `<td style="background:${colour.get(a.section_id)}"><span class="gr">${esc(a.gr_number)}</span><span class="sec">${esc(a.section_name)}${chart.set_count > 1 ? ` · Set ${esc(a.set_code)}` : ''}</span></td>`
            : '<td class="empty"></td>',
        );
      }
      rows.push(`<tr><th>R${r}</th>${cells.join('')}</tr>`);
    }
    grid = `<table class="hall"><thead><tr><th></th>${Array.from({ length: hall.seats_per_row }, (_, i) => `<th>S${i + 1}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table>`;
  }
  const legend = sectionIds
    .map((id) => {
      const a = chart.allocations.find((x) => x.section_id === id)!;
      return `<span class="chip" style="background:${colour.get(id)}">Section ${esc(a.section_name)}</span>`;
    })
    .join(' ');
  const css = `${baseCss(font)}
@page { size: A3 landscape; margin: 10mm; }
h1 { font-size: 14pt; margin: 0; }
.meta { font-size: 9pt; color: #333; margin: 1mm 0 3mm; }
.chip { display: inline-block; padding: 0.5mm 2mm; border: 0.2mm solid #999; margin-right: 2mm; }
table.hall { border-collapse: collapse; width: 100%; table-layout: fixed; }
table.hall th, table.hall td { border: 0.2mm solid #888; padding: 0.6mm; text-align: center; font-size: 7pt; height: 11mm; overflow: hidden; }
table.hall th { background: #eee; }
.gr { display: block; font-weight: 700; }
.sec { display: block; color: #333; font-size: 6.5pt; }`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Seating chart</title><style>${css}</style></head><body>
<h1>${esc(chart.class_name)} · ${esc(chart.subject_name_en)} <span class="ur">${esc(chart.subject_name_ur)}</span></h1>
<div class="meta">${esc(when(chart))} · Hall ${esc(hall?.name)} · ${chart.allocations.length} candidates${chart.set_count > 1 ? ` · ${chart.set_count} paper sets` : ''}</div>
<div class="meta">${legend}</div>
${grid}
</body></html>`;
  return { html, pageFormat: 'A3', landscape: true };
}

export function buildSeatSlipsHtml(chart: SeatingChart, font: ResolvedFont | null): PrintDocument {
  const slips = chart.allocations
    .map(
      (a) => `<div class="slip">
  <div class="top"><span class="subject">${esc(chart.class_name)} · ${esc(chart.subject_name_en)}</span><span class="ur">${esc(chart.subject_name_ur)}</span></div>
  <div class="name">${esc(a.name_en)}${a.name_ur ? ` <span class="ur">${esc(a.name_ur)}</span>` : ''}</div>
  <div class="row"><span>GR ${esc(a.gr_number)}</span><span>Section ${esc(a.section_name)}${a.roll_no ? ` · Roll ${a.roll_no}` : ''}</span></div>
  <div class="row"><span>${esc(chart.hall?.name)}</span><span class="seat">Seat ${esc(a.label)}</span></div>
  <div class="row"><span>${esc(when(chart))}</span><span class="set" data-set="${esc(a.set_code)}">Set ${esc(a.set_code)}</span></div>
</div>`,
    )
    .join('\n');
  const css = `${baseCss(font)}
@page { size: A4 portrait; margin: 10mm; }
.sheet { display: grid; grid-template-columns: 1fr 1fr; gap: 4mm; }
.slip { border: 0.3mm dashed #666; padding: 3mm; break-inside: avoid; height: 52mm; }
.top { display: flex; justify-content: space-between; font-size: 8pt; color: #333; }
.name { font-size: 12pt; font-weight: 700; margin: 2mm 0; }
.row { display: flex; justify-content: space-between; margin-top: 1.5mm; }
.seat { font-size: 13pt; font-weight: 700; }
.set { font-size: 16pt; font-weight: 800; border: 0.4mm solid #111; padding: 0 3mm; }`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Seat slips</title><style>${css}</style></head><body><div class="sheet">${slips || '<p>No seats allocated.</p>'}</div></body></html>`;
  return { html, pageFormat: 'A4', landscape: false };
}
