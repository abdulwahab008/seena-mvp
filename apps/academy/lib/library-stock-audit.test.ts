import { describe, expect, it } from 'vitest';
import { compareStock, type AuditCopy } from './library-stock-audit';

const copy = (barcode: string, status = 'available'): AuditCopy => ({ barcode, status, title: barcode, accession_no: barcode, shelf: null });

describe('compareStock', () => {
  it('splits the shelf scan into found, missing, out-on-register and unknown', () => {
    const r = compareStock([' b1', 'B2', 'b3', 'zz9', 'b1'], [copy('B1'), copy('B2'), copy('B3', 'issued'), copy('B4'), copy('B5', 'lost')]);
    expect(r.found).toBe(2);
    expect(r.missing.map((c) => c.barcode)).toEqual(['B4']);
    expect(r.notAvailable.map((c) => c.barcode)).toEqual(['B3']);
    expect(r.unknown).toEqual(['ZZ9']);
  });
});
