import { describe, expect, it } from 'vitest';
import { capMonthLines, transportFeePaisa } from './prorate';

describe('transportFeePaisa (FR-P04)', () => {
  it('pro-rates an 11 August start in a 31-day month: 3,500 x 21/31 = PKR 2,371', () => {
    expect(transportFeePaisa(350000, '2026-08-11', null, '2026-08-01', 'prorata')).toBe(237100);
  });
  it('charges the full PKR 3,500 from the next month', () => {
    expect(transportFeePaisa(350000, '2026-08-11', null, '2026-09-01', 'prorata')).toBe(350000);
  });
  it('charges the full month in August under the full-month policy', () => {
    expect(transportFeePaisa(350000, '2026-08-11', null, '2026-08-01', 'full_month')).toBe(350000);
  });
  it('is zero before the allocation starts and after it ends', () => {
    expect(transportFeePaisa(350000, '2026-08-11', null, '2026-07-01', 'prorata')).toBe(0);
    expect(transportFeePaisa(350000, '2026-01-01', '2026-07-31', '2026-08-01', 'full_month')).toBe(0);
  });
  it('splits a 16 October move between two slabs and stays within the dearest slab', () => {
    const closing = transportFeePaisa(350000, '2026-01-01', '2026-10-15', '2026-10-01', 'prorata');
    const opening = transportFeePaisa(420000, '2026-10-16', null, '2026-10-01', 'prorata');
    expect(closing).toBe(169400);
    expect(opening).toBe(216800);
    expect(closing + opening).toBeLessThanOrEqual(420000);
  });
  it('handles leap-year February', () => {
    expect(transportFeePaisa(290000, '2028-02-15', null, '2028-02-01', 'prorata')).toBe(150000);
  });
});

describe('capMonthLines', () => {
  it('trims later lines so the month never exceeds the dearest slab', () => {
    expect(capMonthLines([350000, 420000], 420000)).toEqual([350000, 70000]);
    expect(capMonthLines([169400, 216800], 420000)).toEqual([169400, 216800]);
  });
});
