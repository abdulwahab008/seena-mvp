import { describe, expect, it } from 'vitest';
import { allRows } from './all-rows';

describe('allRows', () => {
  it('keeps fetching 1000-row pages until a short page', async () => {
    const source = Array.from({ length: 2345 }, (_, i) => i);
    const calls: number[] = [];
    const { data, error } = await allRows(async (from, to) => {
      calls.push(from);
      return { data: source.slice(from, to + 1), error: null };
    });
    expect(error).toBeNull();
    expect(data).toEqual(source);
    expect(calls).toEqual([0, 1000, 2000]);
  });
});
