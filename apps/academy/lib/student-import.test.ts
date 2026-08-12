import { describe, expect, it } from 'vitest';
import {
  IMPORT_CHUNK_SIZE,
  STUDENT_IMPORT_COLUMNS,
  buildStudentImportTemplateCsv,
  chunkRows,
  formatClassChoices,
  parseCsv,
  toRawRows,
  toStagePayload,
  validateImportHeader,
  validateStudentImportRows,
  type ClassOption,
  type ValidatedImportRow,
} from './student-import';

// The same 14 classes public.seed_default_class_levels() gives every new
// tenant, in ordinal order.
const CLASSES: ClassOption[] = [
  { id: 'c-nur', code: 'NUR', name_en: 'Nursery' },
  { id: 'c-kg', code: 'KG', name_en: 'Kindergarten' },
  ...Array.from({ length: 12 }, (_, i) => ({ id: `c-${i + 1}`, code: String(i + 1), name_en: `Class ${i + 1}` })),
];

const TODAY = new Date(Date.UTC(2026, 7, 13));

const HEADER = STUDENT_IMPORT_COLUMNS.join(',');

function fileOf(...dataLines: string[]): string {
  return `${HEADER}\n${dataLines.join('\n')}\n`;
}

function validate(csv: string): ValidatedImportRow[] {
  const matrix = parseCsv(csv);
  const header = validateImportHeader(matrix[0]!);
  if (!header.ok) throw new Error(`unexpected header rejection: ${header.message}`);
  return validateStudentImportRows(toRawRows(matrix, header.columns), CLASSES, TODAY);
}

// A well-formed row: no GR (allocated at commit), valid class, valid
// B-Form. Used as the baseline every scenario below deviates from. The
// B-Form is unique per generated row so that only the tests that ask for
// a duplicate get one.
let bFormSeq = 0;
function goodRow(overrides: Partial<Record<string, string>> = {}): string {
  const base: Record<string, string> = {
    gr_number: '',
    name_en: 'Ayesha Khan',
    name_ur: '',
    father_name_en: 'Imran Khan',
    father_name_ur: '',
    dob: '2016-04-12',
    gender: 'female',
    class: '1',
    b_form_no: `42101-${String((bFormSeq += 1)).padStart(7, '0')}-1`,
    religion: '',
    nationality: 'PK',
    blood_group: '',
  };
  return STUDENT_IMPORT_COLUMNS.map((c) => ({ ...base, ...overrides })[c] ?? '').join(',');
}

describe('parseCsv', () => {
  it('parses quoted fields containing commas, quotes and newlines', () => {
    const rows = parseCsv('a,"b,1","he said ""hi""","line\nbreak"\n');
    expect(rows).toEqual([['a', 'b,1', 'he said "hi"', 'line\nbreak']]);
  });

  it('normalises CRLF and strips a UTF-8 BOM', () => {
    const rows = parseCsv('﻿gr_number,name_en\r\n1,Ali\r\n');
    expect(rows).toEqual([
      ['gr_number', 'name_en'],
      ['1', 'Ali'],
    ]);
  });

  it('does not emit a trailing empty row for a file ending in a newline', () => {
    expect(parseCsv('a,b\n1,2\n')).toHaveLength(2);
  });
});

describe('validateImportHeader', () => {
  // AC: a header set that does not match the published template is
  // rejected before parsing.
  it('rejects a header with missing and unexpected columns and names both', () => {
    const result = validateImportHeader(['gr_number', 'student_name', 'date_of_birth', 'sex', 'class']);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.missing).toContain('name_en');
    expect(result.missing).toContain('dob');
    expect(result.unexpected).toEqual(['student_name', 'date_of_birth', 'sex']);
    expect(result.message).toContain('do not match the student import template');
    expect(result.message).toContain('Download the template');
  });

  it('rejects a header that repeats a column', () => {
    const result = validateImportHeader([...STUDENT_IMPORT_COLUMNS, 'dob']);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.duplicated).toEqual(['dob']);
  });

  it('accepts the published template regardless of column order and letter case', () => {
    const shuffled = [...STUDENT_IMPORT_COLUMNS].reverse().map((c) => ` ${c.toUpperCase()} `);
    const result = validateImportHeader(shuffled);
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect([...result.columns].sort()).toEqual([...STUDENT_IMPORT_COLUMNS].sort());
  });

  it('accepts the header of the template it publishes', () => {
    const matrix = parseCsv(buildStudentImportTemplateCsv());
    expect(validateImportHeader(matrix[0]!).ok).toBe(true);
    // The example row in the template must itself be importable.
    const rows = validateStudentImportRows(toRawRows(matrix, [...STUDENT_IMPORT_COLUMNS]), CLASSES, TODAY);
    expect(rows.map((r) => r.severity)).toEqual(['ok']);
  });
});

describe('toRawRows', () => {
  it('numbers rows by source line, so the first data row is 2', () => {
    const rows = validate(fileOf(goodRow(), goodRow({ name_en: 'Bilal' })));
    expect(rows.map((r) => r.rowNo)).toEqual([2, 3]);
  });

  it('skips blank lines without shifting the numbering of later rows', () => {
    const rows = validate(fileOf(goodRow(), '', goodRow({ name_en: 'Bilal' })));
    expect(rows.map((r) => r.rowNo)).toEqual([2, 4]);
  });
});

describe('formatClassChoices', () => {
  it('collapses runs of consecutive numeric codes', () => {
    expect(formatClassChoices(CLASSES)).toBe('NUR, KG, 1..12');
  });

  it('leaves a run shorter than three uncollapsed', () => {
    expect(formatClassChoices([{ id: 'a', code: '9', name_en: 'Class 9' }, { id: 'b', code: '10', name_en: 'Class 10' }])).toBe('9, 10');
  });
});

describe('validateStudentImportRows', () => {
  // AC: class names that do not match configured classes block every
  // affected row, with the offending value and the allowed set.
  it('blocks a row whose class is not configured, naming the value and the choices', () => {
    const [row] = validate(fileOf(goodRow({ class: 'Class One' })));
    expect(row!.severity).toBe('error');
    expect(row!.errors).toContainEqual({
      column: 'class',
      code: 'UNKNOWN_CLASS',
      severity: 'error',
      message: "Unknown class 'Class One' - expected one of NUR, KG, 1..12",
    });
  });

  it('accepts a class given by code or by name, case- and space-insensitively', () => {
    const rows = validate(fileOf(goodRow({ class: 'nursery' }), goodRow({ class: ' KG ' }), goodRow({ class: 'Class 7' })));
    expect(rows.map((r) => r.severity)).toEqual(['ok', 'ok', 'ok']);
    expect(rows.map((r) => r.normalised.class_level_id)).toEqual(['c-nur', 'c-kg', 'c-7']);
  });

  // AC: BOTH occurrences of an in-file duplicate GR number are blocked.
  it('blocks both occurrences of a GR number repeated within the file', () => {
    const rows = validate(
      fileOf(
        goodRow({ gr_number: 'MAIN-000042' }),
        goodRow({ gr_number: 'MAIN-000099' }),
        goodRow({ gr_number: 'MAIN-000042' }),
      ),
    );
    expect(rows.map((r) => r.severity)).toEqual(['error', 'ok', 'error']);
    for (const row of [rows[0]!, rows[2]!]) {
      expect(row.errors).toContainEqual({
        column: 'gr_number',
        code: 'DUPLICATE_IN_FILE',
        severity: 'error',
        message: "GR number 'MAIN-000042' appears more than once in this file (rows 2, 4) - every occurrence is blocked.",
      });
    }
  });

  it('blocks every occurrence when a GR number repeats three times', () => {
    const rows = validate(fileOf(...Array.from({ length: 3 }, () => goodRow({ gr_number: 'X-1' }))));
    expect(rows.every((r) => r.severity === 'error')).toBe(true);
  });

  it('blocks both occurrences of a B-Form number repeated within the file', () => {
    const rows = validate(fileOf(goodRow({ b_form_no: '42101-1234567-8' }), goodRow({ b_form_no: '4210112345678' })));
    // Both spellings normalise to the same number, so both are blocked.
    expect(rows.map((r) => r.severity)).toEqual(['error', 'error']);
  });

  // AC: a missing B-Form is a warning; the row stays importable.
  it('reports a missing B-Form number as a warning, not an error', () => {
    const [row] = validate(fileOf(goodRow({ b_form_no: '' })));
    expect(row!.severity).toBe('warning');
    expect(row!.errors).toHaveLength(1);
    expect(row!.errors[0]).toMatchObject({ column: 'b_form_no', code: 'BFORM_MISSING', severity: 'warning' });
  });

  it('blocks a B-Form number that does not resolve to 13 digits', () => {
    const [row] = validate(fileOf(goodRow({ b_form_no: '4210-123' })));
    expect(row!.severity).toBe('error');
    expect(row!.errors[0]).toMatchObject({ column: 'b_form_no', code: 'BFORM_INVALID_FORMAT' });
  });

  it('normalises a B-Form number written without punctuation', () => {
    const [row] = validate(fileOf(goodRow({ b_form_no: '4210112345678' })));
    expect(row!.normalised.b_form_no).toBe('42101-1234567-8');
  });

  it('requires a name, a date of birth and a gender', () => {
    const [row] = validate(fileOf(goodRow({ name_en: '', dob: '', gender: '' })));
    expect(row!.errors.map((e) => `${e.column}:${e.code}`).sort()).toEqual(['dob:REQUIRED', 'gender:REQUIRED', 'name_en:REQUIRED']);
  });

  it('blocks an unparseable date and a date outside the 25-year window', () => {
    const rows = validate(
      fileOf(
        goodRow({ dob: '12/04/2016' }),
        goodRow({ dob: '2016-02-31' }),
        goodRow({ dob: '2027-01-01' }),
        goodRow({ dob: '1990-01-01' }),
      ),
    );
    expect(rows.map((r) => r.errors[0]!.code)).toEqual(['INVALID_DATE', 'INVALID_DATE', 'DOB_OUT_OF_RANGE', 'DOB_OUT_OF_RANGE']);
  });

  it('maps gender aliases and blocks anything else', () => {
    const rows = validate(fileOf(goodRow({ gender: 'M' }), goodRow({ gender: 'Female' }), goodRow({ gender: 'boy' })));
    expect(rows.map((r) => r.normalised.gender)).toEqual(['male', 'female', null]);
    expect(rows[2]!.errors[0]).toMatchObject({ column: 'gender', code: 'UNKNOWN_GENDER' });
  });

  it('defaults nationality to PK when the cell is blank', () => {
    const [row] = validate(fileOf(goodRow({ nationality: '' })));
    expect(row!.normalised.nationality).toBe('PK');
  });

  it('reports only one issue per broken cell', () => {
    // A blank class is both "required" and "not a configured class"; the
    // report must not say both about the same cell.
    const [row] = validate(fileOf(goodRow({ class: '' })));
    expect(row!.errors.filter((e) => e.column === 'class')).toHaveLength(1);
  });

  // AC: 5,000 rows in, 118 blocked, 4,882 ready — and, because this whole
  // module is pure, provably nothing that could create a student row.
  it('counts a large file the way the batch summary does', () => {
    const lines: string[] = [];
    for (let i = 0; i < 4882; i++) lines.push(goodRow({ gr_number: `OK-${i}` }));
    for (let i = 0; i < 118; i++) lines.push(goodRow({ gr_number: `BAD-${i}`, class: 'Class One' }));
    const rows = validate(fileOf(...lines));

    expect(rows).toHaveLength(5000);
    expect(rows.filter((r) => r.severity === 'error')).toHaveLength(118);
    expect(rows.filter((r) => r.severity !== 'error')).toHaveLength(4882);

    // Every blocked row carries a row number, a column and a message.
    for (const row of rows.filter((r) => r.severity === 'error')) {
      expect(row.rowNo).toBeGreaterThan(1);
      for (const issue of row.errors) {
        expect(issue.column).toBeTruthy();
        expect(issue.message).toBeTruthy();
      }
    }
  });

  it('never yields a student row - a dry run only ever produces a report', () => {
    const rows = validate(fileOf(goodRow(), goodRow({ class: 'Class One' })));
    // The staged payload is inert data: raw cells, normalised cells and
    // issues. Nothing here is an insert, an id, or a GR allocation.
    expect(Object.keys(toStagePayload(rows)[0]!).sort()).toEqual(['errors', 'normalised', 'raw', 'row_no']);
    expect(rows.every((r) => !('id' in r) && !('student_id' in r))).toBe(true);
  });
});

describe('chunkRows', () => {
  it('splits 5,000 rows into 10 chunks of 500', () => {
    const chunks = chunkRows(Array.from({ length: 5000 }, (_, i) => i));
    expect(chunks).toHaveLength(10);
    expect(chunks.every((c) => c.length === IMPORT_CHUNK_SIZE)).toBe(true);
    expect(chunks.flat()).toHaveLength(5000);
  });

  it('leaves a short final chunk', () => {
    expect(chunkRows([1, 2, 3], 2)).toEqual([[1, 2], [3]]);
  });
});
