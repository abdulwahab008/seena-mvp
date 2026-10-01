import { describe, expect, it } from 'vitest';
import { distributeColumnWidths, estimateWidthMm, formatPaisa, orientationFor, totalsRow, usableWidthMm, type PdfColumn, type PdfRow } from './pdf-layout';

const cols = (n: number, type: PdfColumn['type'] = 'text'): PdfColumn[] => Array.from({ length: n }, (_, i) => ({ key: `c${i}`, label: `Column ${i + 1}`, type }));
const row = (columns: PdfColumn[], text: string): PdfRow => Object.fromEntries(columns.map((c) => [c.key, text]));

describe('orientation', () => {
  it('stays portrait up to 8 columns and goes landscape automatically above', () => {
    expect(orientationFor(8)).toBe('portrait');
    expect(orientationFor(9)).toBe('landscape');
    expect(orientationFor(14)).toBe('landscape');
  });
  it('gives landscape more usable width', () => {
    expect(usableWidthMm('landscape')).toBeGreaterThan(usableWidthMm('portrait'));
  });
});

describe('distributeColumnWidths', () => {
  it('uses exactly the usable width', () => {
    const c = cols(10);
    const l = distributeColumnWidths(c, [row(c, 'Some typical value')], usableWidthMm('landscape'));
    expect(l.widthsMm.reduce((a, b) => a + b, 0)).toBeCloseTo(usableWidthMm('landscape'), 1);
    expect(l.fits).toBe(true);
  });
  it('never gives a column less than its longest unbreakable word, so no cell text is clipped', () => {
    const c: PdfColumn[] = [
      { key: 'a', label: 'ID', type: 'text' },
      { key: 'b', label: 'Student', type: 'text' },
      { key: 'c', label: 'Reference', type: 'text' },
      ...cols(7).map((x, i) => ({ ...x, key: `x${i}` })),
    ];
    const rows: PdfRow[] = [{ a: '1', b: 'Muhammad Abdul Rehman Siddiqui', c: 'INV/2026/09/000123456789012345' }];
    const l = distributeColumnWidths(c, rows, usableWidthMm('landscape'));
    expect(l.widthsMm[2]!).toBeGreaterThanOrEqual(estimateWidthMm('INV/2026/09/000123456789012345', l.fontPt));
  });
  it('gives wide-content columns more room than narrow ones', () => {
    const c: PdfColumn[] = [{ key: 'n', label: 'No', type: 'int' }, { key: 'name', label: 'Name', type: 'text' }];
    const l = distributeColumnWidths(c, [{ n: 1, name: 'A fairly long student name here' }], usableWidthMm('portrait'));
    expect(l.widthsMm[1]!).toBeGreaterThan(l.widthsMm[0]!);
  });
  it('steps the font down rather than clipping when many columns are requested', () => {
    const c = cols(18);
    const l = distributeColumnWidths(c, [row(c, 'Value-with-length')], usableWidthMm('landscape'));
    expect(l.fontPt).toBeLessThan(9);
  });
  it('reports fits=false (so the job fails loudly) when even the smallest font cannot fit', () => {
    const c = cols(40);
    expect(distributeColumnWidths(c, [row(c, 'Extraordinarily-long-unbreakable-value')], usableWidthMm('landscape')).fits).toBe(false);
  });
});

describe('money and totals', () => {
  it('formats paisa with fixed grouping and two decimals', () => {
    expect(formatPaisa(180000000)).toBe('1,800,000.00');
    expect(formatPaisa(5)).toBe('0.05');
    expect(formatPaisa(-123456)).toBe('-1,234.56');
  });
  it('sums money columns once and labels the row count', () => {
    const c: PdfColumn[] = [{ key: 'n', label: 'Name', type: 'text' }, { key: 'amt', label: 'Amount', type: 'money' }, { key: 'days', label: 'Days', type: 'int' }];
    const t = totalsRow(c, [{ n: 'a', amt: 150000, days: 3 }, { n: 'b', amt: 250000, days: 4 }])!;
    expect(t.label).toBe('Total (2 rows)');
    expect(t.cells).toEqual({ amt: '4,000.00' });
  });
  it('has no totals row when there is nothing to sum', () => {
    expect(totalsRow(cols(3), [])).toBeNull();
  });
});
