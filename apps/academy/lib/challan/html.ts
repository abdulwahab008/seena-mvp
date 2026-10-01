import { z } from 'zod';

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

// Three identical copies on one A4 page, cut-lines between them, every
// dynamic value escaped — the payload carries names typed by staff.
export function buildChallanHtml(p: ChallanPayload): string {
  const rows = p.lines
    .map((l) => `<tr><td>${escapeHtml(l.head_name)}</td><td class="n">${formatPkr(l.amount_paisa)}</td><td class="n">${formatPkr(-l.concession_paisa)}</td><td class="n">${formatPkr(l.net_paisa)}</td></tr>`)
    .join('');
  const copy = (kind: string) => `
  <section class="copy">
    <header><strong>${escapeHtml(COPY_LABEL[kind] ?? kind)}</strong><span class="no">Challan ${escapeHtml(p.challan_no)}</span></header>
    <p>${escapeHtml(p.student.name_en)} · GR ${escapeHtml(p.student.gr_number)} · ${escapeHtml(p.student.class_name)} ${escapeHtml(p.student.section_name)}</p>
    <p>Period ${escapeHtml(p.billing_period)} · Due ${escapeHtml(p.due_date)}</p>
    <table><thead><tr><th>Fee head</th><th class="n">Amount</th><th class="n">Concession</th><th class="n">Net</th></tr></thead><tbody>${rows}</tbody></table>
    ${p.note ? `<p class="note">${escapeHtml(p.note)}</p>` : ''}
    <p>Arrears ${formatPkr(p.arrears_paisa)} · <strong>Payable ${formatPkr(p.net_paisa)}</strong></p>
    <p class="bank">${escapeHtml(p.bank.bank_name)} · ${escapeHtml(p.bank.bank_account_title)} · ${escapeHtml(p.bank.bank_account_no)}</p>
    <p class="foot">${escapeHtml(p.bank.footer_note_en)}</p>
  </section>`;
  return `<!doctype html><html><head><meta charset="utf-8"><title>Challan ${escapeHtml(p.challan_no)}</title>
<style>
@page { size: A4 portrait; margin: 10mm; }
body { font: 11px/1.4 system-ui, sans-serif; color: #111; }
.copy { border-bottom: 1px dashed #666; padding: 4mm 0; height: 88mm; box-sizing: border-box; }
header { display: flex; justify-content: space-between; font-size: 13px; }
table { width: 100%; border-collapse: collapse; margin: 2mm 0; }
th, td { border-bottom: 1px solid #ccc; padding: 1mm 2mm; text-align: left; }
.n { text-align: right; font-variant-numeric: tabular-nums; }
.no { font-family: ui-monospace, monospace; letter-spacing: 1px; }
.foot { color: #555; }
.note { font-style: italic; }
</style></head><body>${p.copies.map(copy).join('')}</body></html>`;
}
