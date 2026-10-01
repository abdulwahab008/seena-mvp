import { describe, expect, it } from 'vitest';
import { buildReportCardPacketHtml, packetDownloadPath } from './packet';
import type { ReportCardSnapshot } from './html';
import type { ChallanPayload } from '@/lib/challan/html';

/**
 * FR-J11. The packet is the card, then the 3-copy challan; with no challan it
 * is the card alone. Nothing here sums a fee: the amount printed is whatever
 * the fee module's payload said.
 */
const snapshot: ReportCardSnapshot = {
  school: { name: 'Seena Public School', campus_name: 'Main', campus_name_ur: null, campus_code: 'M', city: 'Lahore', address_line: null, phone: null },
  branding: { logo_storage_path: null, letterhead_storage_path: null, signature_storage_path: null, stamp_storage_path: null },
  student: { name_en: 'Ayesha Noor', name_ur: null, father_name_en: 'Muhammad Noor', father_name_ur: null, gr_number: 'M-1', roll_no: 4, photo_path: null, class_name: 'Class 5', section_name: 'A' },
  term: { exam_term_id: 't1', code: 'T1', name: 'First Term', name_ur: null, session_name: '2026-27' },
  subjects: [],
  aggregate: { obtained: 0, max_marks: 0, pct: null, grade_label: null, gpa_point: null, is_pass: null },
  grading_scheme: null,
  position: null,
  attendance: { months_counted: 0, present_days: 0, working_days: 0, pct: null, from_date: null, to_date: null },
  remark: null,
  revision_no: 1,
  supersedes_revision: null,
  rendered_at: '2026-09-30T09:00:00.000Z',
};

const challan: ChallanPayload = {
  challan_no: 'CH-2026-0001',
  barcode_value: 'CH-2026-0001',
  billing_period: '2026-11-01',
  issue_date: '2026-10-01',
  due_date: '2026-11-10',
  student: { name_en: 'Ayesha Noor', gr_number: 'M-1', class_name: 'Class 5', section_name: 'A' },
  bank: { bank_name: 'HBL', bank_account_title: 'Seena Public School', bank_account_no: '0042', footer_note_en: null },
  lines: [{ head_name: 'Tuition', amount_paisa: 1000000, concession_paisa: 250000, net_paisa: 750000, line_type: 'charge' }],
  gross_paisa: 1000000,
  concession_paisa: 250000,
  arrears_paisa: 0,
  net_paisa: 750000,
  copies: ['bank', 'school', 'student'],
};

const assets = { letterheadDataUri: null, logoDataUri: null, signatureDataUri: null, stampDataUri: null, photoDataUri: null };

describe('buildReportCardPacketHtml', () => {
  const html = buildReportCardPacketHtml(snapshot, challan, null, assets).html;

  it('AC1: the report card comes first, then the challan', () => {
    const card = html.indexOf('data-report-card');
    const slip = html.indexOf('data-challan-page');
    expect(card).toBeGreaterThan(-1);
    expect(slip).toBeGreaterThan(card);
    expect(html.indexOf('Report Card')).toBeLessThan(slip);
  });

  it('AC1: the challan is the bank, school and student copy, with barcode and due date', () => {
    expect(html.match(/class="copy"/g)).toHaveLength(3);
    expect(html).toContain('Bank copy');
    expect(html).toContain('School copy');
    expect(html).toContain('Student copy');
    expect(html.match(/data-barcode="CH-2026-0001"/g)).toHaveLength(3);
    expect(html).toContain('<rect ');
    expect(html).toContain('Due 2026-11-10');
  });

  it('AC3: prints the fee module payable exactly, with the concession as given', () => {
    expect(html).toContain('Payable PKR 7,500.00');
    expect(html).toContain('-PKR 2,500.00');
  });

  it('starts the challan on a new page', () => {
    expect(html).toMatch(/\.challan-page \{ break-before: page;/);
  });

  it('keeps one @page rule, the card one', () => {
    expect(html.match(/@page/g)).toHaveLength(1);
  });

  it('AC2: with no challan the packet is the card alone', () => {
    const alone = buildReportCardPacketHtml(snapshot, null, null, assets).html;
    expect(alone).toContain('data-report-card');
    expect(alone).not.toContain('data-challan-page');
    expect(alone).not.toContain('Bank copy');
    expect(alone).not.toContain('data-barcode');
  });

  it('escapes names so a student cannot inject markup into the print', () => {
    const evil = buildReportCardPacketHtml(
      { ...snapshot, student: { ...snapshot.student, name_en: '<img src=x onerror=alert(1)>' } },
      { ...challan, student: { ...challan.student, name_en: '<img src=x onerror=alert(1)>' } },
      null,
      assets,
    ).html;
    expect(evil).not.toContain('<img src=x');
  });
});

describe('packetDownloadPath', () => {
  it('is the verified download route', () => {
    expect(packetDownloadPath('abc')).toBe('/api/report-card-packets/abc/download');
  });
});
