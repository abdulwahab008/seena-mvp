import { escapeHtml } from '@/lib/certificates/merge';
import { buildHrDocumentHtml, type HrDocumentInput } from '@/lib/hr/print';
import type { ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';

/** FR-D17: pure helpers for the final settlement statement. Money is integer paisa throughout. */
export type SettlementLineView = { lineType: string; description: string; amountPaisa: number; sign: 1 | -1 };

/** 5161290 -> "51,612.90" (Latin digits: statements are read by bank tellers). */
export function formatRupees(paisa: number): string {
  const abs = Math.abs(Math.trunc(paisa));
  const rupees = Math.floor(abs / 100);
  const cents = String(abs % 100).padStart(2, '0');
  return `${rupees.toLocaleString('en-US')}.${cents}`;
}

/** "1,500.5" -> 150050; null for anything that is not a plain positive amount with at most 2 decimals. */
export function parseRupeesToPaisa(input: string): number | null {
  const cleaned = input.trim().replace(/,/g, '');
  if (!/^\d{1,10}(\.\d{1,2})?$/.test(cleaned)) return null;
  const [r, c = ''] = cleaned.split('.');
  const paisa = Number(r) * 100 + Number(c.padEnd(2, '0'));
  return paisa > 0 ? paisa : null;
}

/** "+51,612.90" for an earning, "-66,666.75" for a deduction. */
export function signedRupees(line: Pick<SettlementLineView, 'amountPaisa' | 'sign'>): string {
  return `${line.sign === -1 ? '-' : '+'}${formatRupees(line.amountPaisa)}`;
}

/** The total is the sum of the already-rounded lines, so the printed lines always tie to it. */
export function netPayablePaisa(lines: readonly Pick<SettlementLineView, 'amountPaisa' | 'sign'>[]): number {
  return lines.reduce((sum, l) => sum + l.sign * l.amountPaisa, 0);
}

export type StatementData = {
  schoolName: string;
  schoolNameUr: string | null;
  staffName: string;
  employeeCode: string;
  exitType: string;
  noticeDate: string | null;
  lastWorkingDate: string;
  version: number;
  approvedAt: string | null;
  approvedByName: string | null;
  lines: SettlementLineView[];
  netPayablePaisa: number;
};

export function buildStatementDocument(data: StatementData, font: ResolvedFont | null): PrintDocument {
  const rows = data.lines
    .map(
      (l) => `<tr><td>${escapeHtml(l.description)}</td><td class="num">${l.sign === 1 ? formatRupees(l.amountPaisa) : ''}</td><td class="num">${l.sign === -1 ? formatRupees(l.amountPaisa) : ''}</td></tr>`,
    )
    .join('\n');
  const net = data.netPayablePaisa;
  const body = `<table class="meta"><tbody>
<tr><td>Employee</td><td><strong>${escapeHtml(data.staffName)}</strong> (${escapeHtml(data.employeeCode)})</td></tr>
<tr><td>Exit</td><td>${escapeHtml(data.exitType.replace(/_/g, ' '))}${data.noticeDate ? `, notice given ${escapeHtml(data.noticeDate)}` : ''}</td></tr>
<tr><td>Last working date</td><td>${escapeHtml(data.lastWorkingDate)}</td></tr>
<tr><td>Statement</td><td>Version ${data.version}${data.approvedAt ? `, approved ${escapeHtml(data.approvedAt.slice(0, 10))}${data.approvedByName ? ` by ${escapeHtml(data.approvedByName)}` : ''}` : ''}</td></tr>
</tbody></table>
<table class="lines"><thead><tr><th>Description</th><th class="num">Dues (PKR)</th><th class="num">Deductions (PKR)</th></tr></thead><tbody>
${rows}
<tr class="total"><td>${net >= 0 ? 'Net payable to the employee' : 'Net recoverable from the employee'}</td><td class="num" colspan="2">${net < 0 ? '-' : ''}${formatRupees(net)}</td></tr>
</tbody></table>`;
  const doc: HrDocumentInput = {
    title: 'Final Settlement Statement',
    schoolName: data.schoolName,
    schoolNameUr: data.schoolNameUr,
    bodyHtml: `${body}<div class="signatures"><div>Prepared by (Accounts)</div><div>Approved by</div><div>Received by employee</div></div>`,
    footerHtml: 'Each line is rounded to the paisa and the net payable is the sum of the rounded lines.',
  };
  return buildHrDocumentHtml(doc, font);
}
