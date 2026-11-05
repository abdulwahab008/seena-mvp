import { escapeHtml } from '@/lib/certificates/merge';
import { buildHrDocumentHtml, collectHrDocumentStrings, type HrDocumentInput } from '@/lib/hr/print';
import { formatPkrCompact } from '@/lib/format-money';
import type { ResolvedFont } from '@/lib/pdf/font';
import type { PrintDocument } from '@/lib/pdf/render';

export type PayslipPayload = {
  school_name: string;
  school_name_ur: string | null;
  campus_name: string | null;
  period_month: string;
  staff_name: string;
  staff_name_ur: string | null;
  employee_code: string;
  designation: string | null;
  payable_days: number;
  unpaid_days: number;
  earnings: { code: string; name: string; amount_paisa: number }[];
  gross_paisa: number;
  deductions: { key: 'attendance' | 'tax' | 'loan' | 'other'; amount_paisa: number }[];
  total_deductions_paisa: number;
  net_paisa: number;
  net_in_words: string;
  loan_outstanding_paisa: number;
  ytd_tax_paisa: number;
  tax_year_start: string;
  tenant_id: string;
  campus_id: string;
  run_id: string;
  staff_id: string;
  run_locked_at: string | null;
};

const DEDUCTION_LABELS: Record<string, [string, string]> = {
  attendance: ['Attendance deduction', 'حاضری کٹوتی'],
  tax: ['Income tax withheld', 'انکم ٹیکس'],
  loan: ['Loan recovery', 'قرض کی وصولی'],
  other: ['Other deductions', 'دیگر کٹوتیاں'],
};

const L = {
  title: ['Salary Slip', 'تنخواہ کی پرچی'],
  earnings: ['Earnings', 'آمدنی'],
  deductions: ['Deductions', 'کٹوتیاں'],
  gross: ['Gross pay', 'کل تنخواہ'],
  totalDed: ['Total deductions', 'کل کٹوتیاں'],
  net: ['Net pay', 'خالص تنخواہ'],
  words: ['In words', 'الفاظ میں'],
  loan: ['Loan outstanding', 'باقی قرض'],
  ytd: ['Tax withheld, year to date', 'سال بھر کا ٹیکس'],
  amount: ['Amount', 'رقم'],
} as const;

const both = ([en, ur]: readonly [string, string]) => `${escapeHtml(en)} <span class="ur" lang="ur" dir="rtl">${escapeHtml(ur)}</span>`;
const money = (p: number) => escapeHtml(formatPkrCompact(p));

function monthLabel(iso: string): string {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' });
}

export function payslipDocumentInput(p: PayslipPayload): HrDocumentInput {
  const rows = (items: [string, number][]) => items.map(([label, amt]) => `<tr><td>${label}</td><td class="num">${money(amt)}</td></tr>`).join('\n');
  const earnings = rows(p.earnings.map((e) => [escapeHtml(e.name), e.amount_paisa]));
  const deductions = rows(p.deductions.map((d) => [both(DEDUCTION_LABELS[d.key] ?? [d.key, d.key]), d.amount_paisa]));
  return {
    title: `${L.title[0]} / ${L.title[1]}`,
    schoolName: p.school_name,
    schoolNameUr: p.school_name_ur,
    place: p.campus_name,
    bodyHtml: `<style>.ur{font-family:'Noto Nastaliq Urdu',serif}</style>
<p><strong>${escapeHtml(p.staff_name)}</strong>${p.staff_name_ur ? ` <span class="ur" lang="ur" dir="rtl">${escapeHtml(p.staff_name_ur)}</span>` : ''}<br />
${escapeHtml(p.employee_code)}${p.designation ? ` · ${escapeHtml(p.designation)}` : ''} · ${escapeHtml(monthLabel(p.period_month))}<br />
Payable days ${p.payable_days} · Unpaid days ${p.unpaid_days}</p>
<table class="lines"><thead><tr><th>${both(L.earnings)}</th><th class="num">${both(L.amount)}</th></tr></thead><tbody>
${earnings}
<tr class="total"><td>${both(L.gross)}</td><td class="num">${money(p.gross_paisa)}</td></tr></tbody></table>
<table class="lines"><thead><tr><th>${both(L.deductions)}</th><th class="num">${both(L.amount)}</th></tr></thead><tbody>
${deductions}
<tr class="total"><td>${both(L.totalDed)}</td><td class="num">${money(p.total_deductions_paisa)}</td></tr></tbody></table>
<table class="lines"><tbody>
<tr class="total"><td>${both(L.net)}</td><td class="num">${money(p.net_paisa)}</td></tr>
<tr><td>${both(L.words)}</td><td>${escapeHtml(p.net_in_words)}</td></tr>
<tr><td>${both(L.loan)}</td><td class="num">${money(p.loan_outstanding_paisa)}</td></tr>
<tr><td>${both(L.ytd)}</td><td class="num">${money(p.ytd_tax_paisa)}</td></tr></tbody></table>`,
    footerHtml: `Computer generated. No signature required.`,
  };
}

export function buildPayslipDocument(p: PayslipPayload, font: ResolvedFont | null): PrintDocument {
  return buildHrDocumentHtml(payslipDocumentInput(p), font);
}

export function payslipStrings(p: PayslipPayload): string[] {
  return [...collectHrDocumentStrings(payslipDocumentInput(p)), p.staff_name_ur ?? ''];
}
