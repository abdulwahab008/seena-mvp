import { describe, expect, it } from 'vitest';
import { detectHeader, normalizeChallanRef, parseAmountToPaisa, parseCsv, parseDate, parseStatement, type MappingProfile } from './parse-statement';

const HBL: MappingProfile = {
  columnMap: { txn_date: 'Date', challan_ref: 'Customer Ref', bank_ref: 'Txn ID', amount: 'Credit' },
  dateFormat: 'DD/MM/YYYY',
  amountSignRule: 'credit_positive',
};

describe('parseAmountToPaisa', () => {
  it.each([
    ['8,500.00', 850000],
    ['8500', 850000],
    ['Rs. 1,234.5', 123450],
    ['0.05', 5],
    ['-300.00', -30000],
  ])('%s -> %d paisa', (input, expected) => expect(parseAmountToPaisa(input)).toBe(expected));
  it.each(['', 'abc', '12.345', '1.2.3', '8,5OO'])('rejects %j', (input) => expect(parseAmountToPaisa(input)).toBeNull());
  it('never drifts like a float would', () => expect(parseAmountToPaisa('0.29')).toBe(29));
});

describe('parseDate', () => {
  it('parses every supported format and rejects impossible dates', () => {
    expect(parseDate('12/08/2026', 'DD/MM/YYYY')).toBe('2026-08-12');
    expect(parseDate('12-08-2026', 'DD-MM-YYYY')).toBe('2026-08-12');
    expect(parseDate('2026-08-12', 'YYYY-MM-DD')).toBe('2026-08-12');
    expect(parseDate('12-Aug-2026', 'DD-Mon-YYYY')).toBe('2026-08-12');
    expect(parseDate('31/02/2026', 'DD/MM/YYYY')).toBeNull();
    expect(parseDate('12/08/2026', 'DD-MM-YYYY')).toBeNull();
  });
});

describe('normalizeChallanRef', () => {
  it('restores leading zeros Excel dropped and strips formatting', () => {
    expect(normalizeChallanRef('17')).toBe('000000000017');
    expect(normalizeChallanRef('0000-0000-0017')).toBe('000000000017');
    expect(normalizeChallanRef('')).toBeNull();
    expect(normalizeChallanRef('1234567890123')).toBeNull();
  });
});

describe('parseCsv', () => {
  it('handles quotes, embedded commas and newlines, CRLF and a BOM', () => {
    expect(parseCsv('﻿a,b\r\n"x,1","he said ""hi"""\r\n\r\n')).toEqual([['a', 'b'], ['x,1', 'he said "hi"']]);
    expect(parseCsv('a,b\n"line1\nline2",2')[1]).toEqual(['line1\nline2', '2']);
  });
});

describe('parseStatement', () => {
  const file = (rows: string[]) => ['Date,Customer Ref,Txn ID,Credit', ...rows].join('\n');

  it('parses a 312-row statement with no failures', () => {
    const rows = Array.from({ length: 312 }, (_, i) => `12/08/2026,${String(i + 1).padStart(12, '0')},TX${i},"8,500.00"`);
    const r = parseStatement(file(rows), HBL);
    expect(r.fatal).toBeNull();
    expect(r.lines).toHaveLength(312);
    expect(r.lines.filter((l) => l.error)).toHaveLength(0);
    expect(r.lines[0]).toMatchObject({ line_no: 2, challan_ref: '000000000001', amount_paisa: 850000, txn_date: '2026-08-12' });
  });

  it('keeps unparseable rows with their raw text and lets the rest proceed', () => {
    const rows = ['12/08/2026,000000000001,TX1,100.00', '12/08/2026,000000000002,TX2,oops', '12/08/2026,,TX3,100.00', '99/99/2026,000000000004,TX4,100.00', '12/08/2026,000000000005,,100.00', '12/08/2026,000000000006,TX6,100.00'];
    const r = parseStatement(file(rows), HBL);
    const bad = r.lines.filter((l) => l.error);
    expect(bad).toHaveLength(4);
    expect(bad[0]!.raw_line).toBe('12/08/2026,000000000002,TX2,oops');
    expect(r.lines.filter((l) => !l.error)).toHaveLength(2);
  });

  it('reads leading-zero-stripped refs as text and left-pads to 12 digits', () => {
    const r = parseStatement(file(['12/08/2026,17,TX1,100.00']), HBL);
    expect(r.lines[0]!.challan_ref).toBe('000000000017');
  });

  it('supports a bank with a different column order through its mapping profile', () => {
    const profile: MappingProfile = { columnMap: { txn_date: 'Value Date', challan_ref: 'Narration', bank_ref: 'Ref', debit: 'Dr', credit: 'Cr' }, dateFormat: 'YYYY-MM-DD', amountSignRule: 'separate_columns' };
    const csv = 'Ref,Dr,Cr,Narration,Value Date\nB1,,"2,000.00",000000000017,2026-08-12\nB2,500.00,,000000000018,2026-08-12';
    const r = parseStatement(csv, profile);
    expect(r.lines[0]).toMatchObject({ amount_paisa: 200000, challan_ref: '000000000017', error: null });
    expect(r.lines[1]!.error).toContain('NOT_A_CREDIT');
  });

  it('reports mapped columns that are missing from the file instead of guessing', () => {
    const r = parseStatement('Foo,Bar\n1,2', HBL);
    expect(r.fatal).toContain('Customer Ref');
    expect(r.lines).toHaveLength(0);
  });

  it('exposes the header for the mapping preview', () => {
    expect(detectHeader('Date, Customer Ref ,Txn ID\n1,2,3')).toEqual(['Date', 'Customer Ref', 'Txn ID']);
  });
});
