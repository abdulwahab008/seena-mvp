import { describe, expect, it } from 'vitest';
import { normaliseIsbn13, parseCopyCsv } from './library';
import { parseCsv } from './student-import';

describe('parseCopyCsv (FR-O02)', () => {
  it('parses rows and converts PKR to integer paisa', () => {
    const { rows, errors } = parseCopyCsv(parseCsv('accession_no,barcode,isbn,shelf,purchase_cost_pkr,acquired_on\nLIB-1,BC1,978-969-352-601-1,A1,850.50,2026-08-01\n'));
    expect(errors).toEqual([]);
    expect(rows).toEqual([{ accession_no: 'LIB-1', barcode: 'BC1', isbn: '978-969-352-601-1', shelf: 'A1', purchase_cost: 85050, acquired_on: '2026-08-01' }]);
  });

  it('reports 1-based data row numbers for bad rows', () => {
    const { errors } = parseCopyCsv(parseCsv('accession_no,barcode,isbn,purchase_cost_pkr\nL1,B1,9789693526011,100\nL2,,9789693526011,100\nL3,B3,9789693526011,abc\nL4,B4,,\n'));
    expect(errors.map((e) => e.row)).toEqual([2, 3, 4]);
  });

  it('rejects a file without the required header', () => {
    expect(parseCopyCsv(parseCsv('foo,bar\n1,2\n')).errors[0]?.row).toBe(0);
  });

  it('skips blank lines', () => {
    expect(parseCopyCsv(parseCsv('accession_no,barcode,title_id\nA,B,x\n,,\n')).rows).toHaveLength(1);
  });
});

describe('normaliseIsbn13 (FR-O01)', () => {
  it('strips hyphens and spaces from an ISBN-13', () => {
    expect(normaliseIsbn13('978-969-352-601-1')).toBe('9789693526011');
    expect(normaliseIsbn13(' 978 969 352 601 1 ')).toBe('9789693526011');
  });

  it('upgrades a valid ISBN-10 to its ISBN-13', () => {
    expect(normaliseIsbn13('0-306-40615-2')).toBe('9780306406157');
    expect(normaliseIsbn13('080442957X')).toBe('9780804429573');
  });

  it('treats blank as no ISBN', () => {
    expect(normaliseIsbn13(null)).toBeNull();
    expect(normaliseIsbn13('')).toBeNull();
    expect(normaliseIsbn13('  - ')).toBeNull();
  });

  it('rejects a bad checksum or a malformed value', () => {
    expect(() => normaliseIsbn13('9789693526012')).toThrow('ISBN_INVALID');
    expect(() => normaliseIsbn13('0-306-40615-3')).toThrow('ISBN_INVALID');
    expect(() => normaliseIsbn13('12345')).toThrow('ISBN_INVALID');
    expect(() => normaliseIsbn13('abcdefghij')).toThrow('ISBN_INVALID');
    expect(() => normaliseIsbn13('1234567890123')).toThrow('ISBN_INVALID');
  });

  it('the same work in two notations normalises to one value', () => {
    expect(normaliseIsbn13('978-969-352-601-1')).toBe(normaliseIsbn13('9789693526011'));
  });
});
