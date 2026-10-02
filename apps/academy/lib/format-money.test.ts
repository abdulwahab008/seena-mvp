import { describe, expect, it } from 'vitest';
import { formatPct, formatPkrCompact } from './format-money';

describe('formatPkrCompact', () => {
  it.each([
    [180000000, 'PKR 18.00 L'],
    [420000000, 'PKR 42.00 L'],
    [850000, 'PKR 8,500'],
    [1500000000, 'PKR 1.50 Cr'],
    [-250000, 'PKR 2,500'.replace('PKR', '-PKR')],
    [0, 'PKR 0'],
  ])('%d paisa -> %s', (paisa, expected) => expect(formatPkrCompact(paisa)).toBe(expected));
});

describe('formatPct', () => {
  it('prints one decimal and a dash for no data', () => {
    expect(formatPct(70)).toBe('70.0%');
    expect(formatPct(null)).toBe('—');
  });
});
