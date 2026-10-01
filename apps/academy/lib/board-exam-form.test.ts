import { describe, expect, it } from 'vitest';
import {
  boardExamFormFileName,
  buildBoardExamFormCsv,
  reconciliationHeadline,
  sortErrors,
  type ExportError,
} from './board-exam-form';

/** FR-T12. The wording and the file, away from the database. */
describe('reconciliationHeadline', () => {
  it('AC1: PKR 817,800 computed against PKR 810,500 collected, PKR 7,300 short', () => {
    expect(
      reconciliationHeadline({ computed_total_paisa: 81780000, collected_total_paisa: 81050000, difference_paisa: 730000 }),
    ).toBe('PKR 817,800 computed, PKR 810,500 collected — PKR 7,300 short of what must be remitted.');
  });

  it('says so when the deposit matches the collection', () => {
    expect(reconciliationHeadline({ computed_total_paisa: 100000, collected_total_paisa: 100000, difference_paisa: 0 })).toContain(
      'matches the collection',
    );
  });

  it('flags an over-collection instead of calling it a shortfall', () => {
    expect(reconciliationHeadline({ computed_total_paisa: 100000, collected_total_paisa: 110000, difference_paisa: -10000 })).toContain(
      'PKR 100 collected beyond what the board charges',
    );
  });

  it('keeps the paisa when the figure is not a whole rupee', () => {
    expect(reconciliationHeadline({ computed_total_paisa: 10050, collected_total_paisa: 0, difference_paisa: 10050 })).toContain('PKR 100.50');
  });
});

describe('buildBoardExamFormCsv', () => {
  const headers = ['Roll No', 'Candidate Name', 'Subjects', 'Fee (PKR)'];

  it('writes a BOM, CRLF and quotes what needs quoting', () => {
    const csv = buildBoardExamFormCsv(headers, [
      { registration_id: 'a', cells: ['700001', 'Zara, Engineer', 'PHY CHM MTH', '2650.00'] },
      { registration_id: 'b', cells: [null, 'Yusuf "Y" Improver', 'ENG PHY', '3800.00'] },
    ]);
    expect(csv.startsWith('﻿')).toBe(true);
    expect(csv.split('\r\n')).toHaveLength(4);
    expect(csv).toContain('"Zara, Engineer"');
    expect(csv).toContain('"Yusuf ""Y"" Improver"');
  });

  it('leaves an empty roll number empty, not "null"', () => {
    const csv = buildBoardExamFormCsv(headers, [{ registration_id: 'a', cells: [null, 'A', 'ENG', '1900.00'] }]);
    expect(csv).not.toContain('null');
    expect(csv.split('\r\n')[1]).toBe(',A,ENG,1900.00');
  });
});

describe('boardExamFormFileName', () => {
  it('is board, year and a run suffix', () => {
    expect(boardExamFormFileName('PUNJAB', 2026, '12345678-aaaa')).toBe('PUNJAB-EXAM-FORM-2026-12345678.csv');
    expect(boardExamFormFileName('aku eb', 2026, 'abcdef0123')).toBe('AKU-EB-EXAM-FORM-2026-abcdef01.csv');
  });
});

describe('sortErrors', () => {
  const e = (over: Partial<ExportError>): ExportError => ({
    registration_id: 'r',
    student_name: 'A',
    gr_number: 'G',
    rule_code: 'X',
    severity: 'blocking',
    subject_code: null,
    message: '',
    ...over,
  });

  it('puts blocking errors first, then by student', () => {
    const sorted = sortErrors([
      e({ student_name: 'B', severity: 'warning' }),
      e({ student_name: 'Z' }),
      e({ student_name: 'A', severity: 'warning' }),
      e({ student_name: 'C' }),
    ]);
    expect(sorted.map((x) => `${x.severity}:${x.student_name}`)).toEqual(['blocking:C', 'blocking:Z', 'warning:A', 'warning:B']);
  });
});
