import { z } from 'zod';
import { code128bSvg } from './barcode';

const linePayload = z.object({
  head_name: z.string().nullable(),
  amount_paisa: z.number(),
  concession_paisa: z.number(),
  net_paisa: z.number(),
  line_type: z.string(),
});

// The shape build_challan_render_payload / portal_challan_payload return.
export const challanPayloadSchema = z.object({
  challan_no: z.string(),
  // FR-K10 / FR-J11: exactly the challan number, drawn as a Code 128 barcode when present.
  barcode_value: z.string().nullable().optional(),
  billing_period: z.string(),
  issue_date: z.string().nullable(),
  due_date: z.string(),
  student: z.object({ name_en: z.string().nullable(), gr_number: z.string().nullable(), class_name: z.string().nullable(), section_name: z.string().nullable() }),
  bank: z.object({ bank_name: z.string().nullable(), bank_account_title: z.string().nullable(), bank_account_no: z.string().nullable(), footer_note_en: z.string().nullable() }),
  lines: z.array(linePayload),
  gross_paisa: z.number(),
  concession_paisa: z.number(),
  arrears_paisa: z.number(),
  net_paisa: z.number(),
  copies: z.array(z.string()),
  note: z.string().nullable().optional(),
});
export type ChallanPayload = z.infer<typeof challanPayloadSchema>;

export function escapeHtml(value: string | null | undefined): string {
  return (value ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);
}

export function formatPkr(paisa: number): string {
  const sign = paisa < 0 ? '-' : '';
  const abs = Math.abs(paisa);
  return `${sign}PKR ${Math.floor(abs / 100).toLocaleString('en-PK')}.${String(abs % 100).padStart(2, '0')}`;
}

const COPY_LABEL: Record<string, string> = { bank: 'Bank copy', school: 'School copy', student: 'Student copy' };

export const CHALLAN_CSS = `
@page { size: A4 portrait; margin: 10mm; }
body { font: 11px/1.4 system-ui, sans-serif; color: #111; }
.copy { border-bottom: 1px dashed #666; padding: 4mm 0; height: 88mm; box-sizing: border-box; overflow: hidden; }
.copy header { display: flex; justify-content: space-between; font-size: 13px; }
.copy p { margin: 1mm 0; }
.copy table { width: 100%; border-collapse: collapse; margin: 2mm 0; }
.copy th, .copy td { border-bottom: 1px solid #ccc; padding: 1mm 2mm; text-align: left; }
.copy .n { text-align: right; font-variant-numeric: tabular-nums; }
.copy .no { font-family: ui-monospace, monospace; letter-spacing: 1px; }
.copy .foot { color: #555; }
.copy .note { font-style: italic; }
.copy .barcode { margin: 1mm 0; line-height: 0; }
.copy .barcode svg { height: 7mm; width: auto; max-width: 100%; }
`;

// A value Code 128 cannot carry must not take the whole challan down with it.
function safeBarcode(value: string): string {
  try {
    return code128bSvg(value, { moduleWidth: 1.2, height: 30 });
  } catch {
    return '';
  }
}

// Three identical copies, cut-lines between them, every dynamic value escaped
// — the payload carries names typed by staff. Exported without the document
// around it so FR-J11's packet can follow a report card with exactly the page
// the standalone challan prints.
export function challanCopiesHtml(p: ChallanPayload): string {
  const rows = p.lines
    .map((l) => `<tr><td>${escapeHtml(l.head_name)}</td><td class="n">${formatPkr(l.amount_paisa)}</td><td class="n">${formatPkr(-l.concession_paisa)}</td><td class="n">${formatPkr(l.net_paisa)}</td></tr>`)
    .join('');
  const barcode = p.barcode_value ? safeBarcode(p.barcode_value) : '';
  const copy = (kind: string) => `
  <section class="copy">
    <header><strong>${escapeHtml(COPY_LABEL[kind] ?? kind)}</strong><span class="no">Challan ${escapeHtml(p.challan_no)}</span></header>
    <p>${escapeHtml(p.student.name_en)} · GR ${escapeHtml(p.student.gr_number)} · ${escapeHtml(p.student.class_name)} ${escapeHtml(p.student.section_name)}</p>
    <p>Period ${escapeHtml(p.billing_period)} · Due ${escapeHtml(p.due_date)}</p>
    <table><thead><tr><th>Fee head</th><th class="n">Amount</th><th class="n">Concession</th><th class="n">Net</th></tr></thead><tbody>${rows}</tbody></table>
    ${p.note ? `<p class="note">${escapeHtml(p.note)}</p>` : ''}
    <p>Arrears ${formatPkr(p.arrears_paisa)} · <strong>Payable ${formatPkr(p.net_paisa)}</strong></p>
    ${barcode ? `<div class="barcode" data-barcode="${escapeHtml(p.barcode_value)}">${barcode}</div>` : ''}
    <p class="bank">${escapeHtml(p.bank.bank_name)} · ${escapeHtml(p.bank.bank_account_title)} · ${escapeHtml(p.bank.bank_account_no)}</p>
    <p class="foot">${escapeHtml(p.bank.footer_note_en)}</p>
  </section>`;
  return p.copies.map(copy).join('');
}

export function buildChallanHtml(p: ChallanPayload): string {
  return `<!doctype html><html><head><meta charset="utf-8"><title>Challan ${escapeHtml(p.challan_no)}</title>
<style>${CHALLAN_CSS}</style></head><body>${challanCopiesHtml(p)}</body></html>`;
}
