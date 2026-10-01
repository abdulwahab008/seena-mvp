import { describe, expect, it } from 'vitest';
import { normaliseIsbn13 } from './library';

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
