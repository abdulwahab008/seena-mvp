import { z } from 'zod';
import { escapeHtml, formatPkr } from '@/lib/challan/html';
import { code128bSvg, BarcodeError } from '@/lib/challan/barcode';

export const admitCardBatchSchema = z.object({
  term: z.string(),
  class_name: z.string(),
  students: z.array(
    z.object({
      name: z.string(),
      father_name: z.string().nullable(),
      gr_number: z.string(),
      balance_paisa: z.number(),
      papers: z.array(z.object({ subject: z.string(), start_at: z.string(), end_at: z.string(), hall: z.string().nullable(), seat: z.string().nullable() })),
    }),
  ),
});
export type AdmitCardBatch = z.infer<typeof admitCardBatchSchema>;

const TZ = 'Asia/Karachi';
const day = (iso: string) => new Date(iso).toLocaleDateString('en-GB', { timeZone: TZ, weekday: 'short', day: '2-digit', month: 'short', year: 'numeric' });
const time = (iso: string) => new Date(iso).toLocaleTimeString('en-GB', { timeZone: TZ, hour: '2-digit', minute: '2-digit' });

function barcode(text: string) {
  try {
    return code128bSvg(text, { moduleWidth: 1, height: 26 });
  } catch (e) {
    if (e instanceof BarcodeError) return '';
    throw e;
  }
}

const CSS = `
@page { size: A4 portrait; margin: 10mm; }
* { box-sizing: border-box; }
body { margin: 0; font-family: Arial, sans-serif; font-size: 9.5pt; color: #111; }
.slip { height: 136mm; border: 0.3mm solid #444; border-radius: 2mm; padding: 5mm 6mm; margin-bottom: 5mm; break-inside: avoid; position: relative; }
.slip:nth-child(2n) { break-after: page; }
header { display: flex; justify-content: space-between; align-items: flex-start; border-bottom: 0.3mm solid #444; padding-bottom: 2mm; margin-bottom: 2mm; }
header h1 { font-size: 13pt; margin: 0; }
header p { margin: 0.5mm 0 0; color: #333; }
.who { display: grid; grid-template-columns: 1fr 1fr; gap: 1mm 6mm; margin-bottom: 3mm; }
.who span { color: #555; }
table { width: 100%; border-collapse: collapse; }
th, td { border: 0.2mm solid #999; padding: 1.2mm 2mm; text-align: left; }
th { background: #f1f1f1; }
.held { position: absolute; inset: 40mm 10mm auto; text-align: center; font-size: 20pt; font-weight: 700; color: #b91c1c; border: 1mm solid #b91c1c; padding: 4mm; background: rgba(255,255,255,.9); transform: rotate(-8deg); }
footer { position: absolute; bottom: 4mm; left: 6mm; right: 6mm; display: flex; justify-content: space-between; font-size: 8pt; color: #444; }
`;

export function buildAdmitCardsHtml(batch: AdmitCardBatch, schoolName: string): string {
  const slips = batch.students
    .map((s) => {
      const rows = s.papers
        .map((p) => `<tr><td>${escapeHtml(day(p.start_at))}</td><td>${escapeHtml(time(p.start_at))}–${escapeHtml(time(p.end_at))}</td><td>${escapeHtml(p.subject)}</td><td>${escapeHtml(p.hall ?? '—')}</td><td>${escapeHtml(p.seat ?? '—')}</td></tr>`)
        .join('');
      const held = s.balance_paisa > 0 ? `<div class="held">HELD: fees of ${escapeHtml(formatPkr(s.balance_paisa))} outstanding</div>` : '';
      return `<section class="slip">
  <header><div><h1>${escapeHtml(schoolName)}</h1><p>Admit card · ${escapeHtml(batch.term)}</p></div>${barcode(s.gr_number)}</header>
  <div class="who"><div><span>Name:</span> <strong>${escapeHtml(s.name)}</strong></div><div><span>GR No:</span> ${escapeHtml(s.gr_number)}</div>
  <div><span>Father:</span> ${escapeHtml(s.father_name ?? '—')}</div><div><span>Class:</span> ${escapeHtml(batch.class_name)}</div></div>
  <table><thead><tr><th>Date</th><th>Time</th><th>Paper</th><th>Hall</th><th>Seat</th></tr></thead><tbody>${rows || '<tr><td colspan="5">No papers scheduled.</td></tr>'}</tbody></table>
  ${held}
  <footer><span>Bring this card to every paper. Arrive 15 minutes early.</span><span>Controller of Examinations</span></footer>
</section>`;
    })
    .join('\n');
  return `<!doctype html><html><head><meta charset="utf-8"><style>${CSS}</style></head><body>${slips}</body></html>`;
}
