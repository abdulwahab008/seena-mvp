import { describe, expect, it } from 'vitest';
import { buildChallanHtml, challanPayloadSchema, escapeHtml, formatPkr, type ChallanPayload } from './html';

const payload: ChallanPayload = {
  challan_no: '000000000017',
  billing_period: '2026-10-01',
  issue_date: '2026-10-01',
  due_date: '2026-10-10',
  student: { name_en: '<script>alert(1)</script> Ali', gr_number: 'GR-1', class_name: 'Class 1', section_name: 'A' },
  bank: { bank_name: 'HBL', bank_account_title: 'School & Co', bank_account_no: '123', footer_note_en: null },
  lines: [{ head_name: 'Tuition', amount_paisa: 850000, concession_paisa: 50000, net_paisa: 800000, line_type: 'charge' }],
  gross_paisa: 850000,
  concession_paisa: 50000,
  arrears_paisa: 0,
  net_paisa: 800000,
  copies: ['bank', 'school', 'student'],
};

describe('formatPkr', () => {
  it('prints paisa exactly, with grouping', () => {
    expect(formatPkr(850000)).toBe('PKR 8,500.00');
    expect(formatPkr(5)).toBe('PKR 0.05');
    expect(formatPkr(-50000)).toBe('-PKR 500.00');
  });
});

describe('buildChallanHtml', () => {
  const html = buildChallanHtml(payload);
  it('renders the three copies', () => {
    expect(html.match(/class="copy"/g)).toHaveLength(3);
    expect(html).toContain('Bank copy');
    expect(html).toContain('Student copy');
  });
  it('escapes staff-typed values so a name cannot inject markup', () => {
    expect(html).not.toContain('<script>');
    expect(html).toContain('&lt;script&gt;');
    expect(html).toContain('School &amp; Co');
  });
  it('prints the concession-withheld note, escaped, only when there is one', () => {
    expect(html).not.toContain('class="note"');
    const noted = buildChallanHtml({ ...payload, note: 'Merit concession withheld: attendance 87.4% below required 90% <b>' });
    expect(noted).toContain('Merit concession withheld: attendance 87.4% below required 90% &lt;b&gt;');
  });
  it('shows the payable amount and challan number', () => {
    expect(html).toContain('Payable PKR 8,000.00');
    expect(html).toContain('Challan 000000000017');
  });
});

describe('challanPayloadSchema', () => {
  it('accepts the payload shape and rejects a malformed one', () => {
    expect(challanPayloadSchema.safeParse(payload).success).toBe(true);
    expect(challanPayloadSchema.safeParse({ ...payload, net_paisa: '800' }).success).toBe(false);
  });
  it('escapeHtml handles null', () => expect(escapeHtml(null)).toBe(''));
});
