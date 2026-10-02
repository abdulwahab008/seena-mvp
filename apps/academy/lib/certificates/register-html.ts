import type { PrintDocument } from '@/lib/pdf/render';
import { escapeHtml } from './merge';

/**
 * FR-T08: the bound-register equivalent, on paper.
 *
 * AC3's deliverable is what a district education officer is handed during
 * an inspection, so the page is a ledger and not a report: one line per
 * serial, in serial order, every serial the campus ever allocated present
 * whatever became of it, and a cancelled line struck through in place with
 * its reason and the serial that replaced it — never removed, never
 * renumbered. The continuity line at the top is the claim an inspector
 * would otherwise have to verify by hand.
 *
 * Landscape A4 because the register is wide (serial, date, GR, student,
 * class, status, reason, cross-reference) and a wrapped column in a
 * statutory register is a column that gets misread. Same seam as every
 * other PDF in this codebase — the caller owns the HTML, lib/pdf/render.ts
 * owns the bytes.
 */

export type RegisterRow = {
  serial_seq: number | null;
  serial_no: string;
  status: 'issued' | 'void' | 'cancelled';
  issued_at: string;
  gr_number: string | null;
  student_name: string | null;
  class_name: string | null;
  cancelled_at: string | null;
  cancelled_reason: string | null;
  cancelled_by_name: string | null;
  replaced_by_serial_no: string | null;
  replaces_serial_no: string | null;
};

export type RegisterContinuity = {
  expected_count: number;
  present_count: number;
  unnumbered_count: number;
  counter_value: number;
  missing_seq: number[];
  first_serial: string | null;
  last_serial: string | null;
};

export type RegisterMeta = {
  schoolName: string;
  campusLabel: string;
  certificateTypeLabel: string;
  academicYearLabel: string;
  printedAt: string;
  printedBy: string | null;
};

const STATUS_LABEL: Record<RegisterRow['status'], string> = {
  issued: 'ISSUED',
  void: 'VOID',
  cancelled: 'CANCELLED',
};

/** DD-MM-YYYY, the one date format FR-T03 established for issued documents. */
export function registerDate(iso: string | null): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return `${String(d.getUTCDate()).padStart(2, '0')}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-${d.getUTCFullYear()}`;
}

/**
 * The sentence an inspector reads first. Deliberately states the gap rather
 * than hiding it: a register that has lost a number has to say so, and a
 * register that has not should be able to prove it in one line.
 */
export function continuityStatement(c: RegisterContinuity | null): string {
  if (!c || c.expected_count === 0) return 'No serials have been allocated in this series.';
  const run = `Serials ${c.first_serial ?? '—'} to ${c.last_serial ?? '—'} (${c.expected_count} allocated, ${c.present_count} on the page)`;
  const unnumbered = c.unnumbered_count > 0 ? ` ${c.unnumbered_count} entry(ies) carry no allocated serial.` : '';
  if (c.missing_seq.length === 0) {
    return `${run} — a continuous run with no missing numbers.${unnumbered}`;
  }
  return `${run} — ${c.missing_seq.length} MISSING NUMBER(S): ${c.missing_seq.join(', ')}.${unnumbered}`;
}

function rowHtml(row: RegisterRow): string {
  const cancelled = row.status === 'cancelled';
  const note = cancelled
    ? [row.cancelled_reason, row.cancelled_by_name ? `by ${row.cancelled_by_name}` : null, registerDate(row.cancelled_at)]
        .filter(Boolean)
        .join(' · ')
    : row.status === 'void'
      ? 'Document never issued'
      : '';
  const crossRef = row.replaced_by_serial_no
    ? `Replaced by ${row.replaced_by_serial_no}`
    : row.replaces_serial_no
      ? `Replaces ${row.replaces_serial_no}`
      : '';
  return `<tr class="${row.status}">
  <td class="seq">${row.serial_seq ?? '—'}</td>
  <td class="serial">${escapeHtml(row.serial_no)}</td>
  <td>${escapeHtml(registerDate(row.issued_at))}</td>
  <td>${escapeHtml(row.gr_number ?? '')}</td>
  <td>${escapeHtml(row.student_name ?? '')}</td>
  <td>${escapeHtml(row.class_name ?? '')}</td>
  <td class="status">${STATUS_LABEL[row.status]}</td>
  <td>${escapeHtml(note)}</td>
  <td>${escapeHtml(crossRef)}</td>
</tr>`;
}

function css(): string {
  return `@page { size: A4 landscape; margin: 10mm 12mm; }
* { box-sizing: border-box; }
html, body { margin: 0; padding: 0; }
body { font-family: 'Times New Roman', Times, Georgia, serif; font-size: 8.5pt; color: #111;
  -webkit-print-color-adjust: exact; print-color-adjust: exact; }
header { border-bottom: 0.6mm solid #111; padding-bottom: 2mm; margin-bottom: 3mm; }
header .school { font-size: 14pt; font-weight: 700; }
header .title { font-size: 11pt; font-weight: 700; letter-spacing: 0.3mm; text-transform: uppercase; }
header .meta { font-size: 8pt; color: #333; }
.continuity { border: 0.3mm solid #111; padding: 1.5mm 2mm; margin-bottom: 3mm; font-size: 8.5pt; font-weight: 700; }
table { width: 100%; border-collapse: collapse; }
thead { display: table-header-group; }
th, td { border: 0.15mm solid #666; padding: 0.8mm 1.2mm; vertical-align: top; }
th { background: #eee; font-size: 8pt; text-align: left; }
tr { page-break-inside: avoid; }
td.seq, td.serial, td.status { white-space: nowrap; }
td.serial { font-family: 'Courier New', monospace; }
tr.cancelled td.serial, tr.void td.serial { text-decoration: line-through; }
tr.cancelled { background: #f2f2f2; }
tr.cancelled td.status, tr.void td.status { font-weight: 700; }
footer { margin-top: 4mm; font-size: 7.5pt; color: #333; display: flex; justify-content: space-between; }`;
}

export function buildRegisterHtml(
  rows: RegisterRow[],
  continuity: RegisterContinuity | null,
  meta: RegisterMeta,
): PrintDocument {
  const title = `Certificate register — ${meta.certificateTypeLabel} — ${meta.academicYearLabel}`;
  const body = rows.map(rowHtml).join('\n');
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(title)}</title><style>${css()}</style></head><body>
<header>
  <div class="school">${escapeHtml(meta.schoolName)}</div>
  <div class="title">Statutory certificate register</div>
  <div class="meta">${escapeHtml(meta.campusLabel)} · ${escapeHtml(meta.certificateTypeLabel)} · ${escapeHtml(meta.academicYearLabel)}</div>
</header>
<div class="continuity">${escapeHtml(continuityStatement(continuity))}</div>
<table>
  <thead><tr>
    <th>#</th><th>Serial no.</th><th>Issued on</th><th>GR no.</th><th>Student</th>
    <th>Class</th><th>Status</th><th>Cancellation / note</th><th>Cross-reference</th>
  </tr></thead>
  <tbody>${body}</tbody>
</table>
<footer>
  <span>${escapeHtml(`${rows.length} entr${rows.length === 1 ? 'y' : 'ies'} printed`)}</span>
  <span>${escapeHtml(`Printed ${meta.printedAt}${meta.printedBy ? ` by ${meta.printedBy}` : ''}`)}</span>
</footer>
</body></html>`;

  return { html, pageFormat: 'A4', landscape: true };
}
