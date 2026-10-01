import { describe, expect, it } from 'vitest';
import { csvEscape, toCsv } from './csv';

describe('csvEscape', () => {
  it('quotes commas, quotes and newlines', () => {
    expect(csvEscape('a,b')).toBe('"a,b"');
    expect(csvEscape('say "hi"')).toBe('"say ""hi"""');
    expect(csvEscape('l1\nl2')).toBe('"l1\nl2"');
  });
  it('defuses spreadsheet formulas', () => {
    for (const bad of ['=SUM(A1)', '+1', '-2', '@cmd']) expect(csvEscape(bad).startsWith("'")).toBe(true);
  });
  it('writes null as empty, objects as JSON, numbers as-is', () => {
    expect(csvEscape(null)).toBe('');
    expect(csvEscape(undefined)).toBe('');
    expect(csvEscape(12)).toBe('12');
    expect(csvEscape({ a: 1 })).toBe('"{""a"":1}"');
  });
});

describe('toCsv', () => {
  it('joins with CRLF and a trailing newline', () => {
    expect(toCsv(['a', 'b'], [[1, 'x,y']])).toBe('a,b\r\n1,"x,y"\r\n');
  });
});
