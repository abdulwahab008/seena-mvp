import { describe, expect, it } from 'vitest';
import { BarcodeError, code128bModules, code128bSvg, code128bValues, code128bWidths } from './barcode';

/**
 * FR-J11 AC1: the challan carries a scannable barcode. The pattern table is the
 * one thing that cannot be eyeballed, so these tests check the structural
 * invariants every valid Code 128 symbol has, and decode what was encoded.
 */
const PATTERNS_FOR_TEST = (() => {
  // Re-derive each symbol's width string from the encoder, one character at a time.
  const out: string[] = [];
  for (let v = 0; v < 103; v += 1) {
    const ch = String.fromCharCode(v + 32);
    if (v + 32 > 126) break;
    const widths = code128bWidths(ch);
    out[v] = widths.slice(6, 12).join(''); // start (6) | char (6) | checksum | stop
  }
  return out;
})();

describe('Code 128 subset B', () => {
  it('encodes start B, the data, a mod-103 checksum and the stop', () => {
    // "PJJ123" -> classic check: 104 + 48*1 + 42*2 + 42*3 + 17*4 + 18*5 + 19*6 = 104+48+84+126+68+90+114 = 634; 634 mod 103 = 16
    expect(code128bValues('PJJ123')).toEqual([104, 48, 42, 42, 17, 18, 19, 16, 106]);
  });

  it('draws every data symbol in 11 modules with three bars and three spaces', () => {
    for (let v = 0; v < PATTERNS_FOR_TEST.length; v += 1) {
      const p = PATTERNS_FOR_TEST[v]!;
      if (!p) continue;
      expect(p).toHaveLength(6);
      expect(p.split('').map(Number).reduce((a, b) => a + b, 0)).toBe(11);
    }
  });

  it('gives every symbol a distinct pattern', () => {
    const seen = new Set(PATTERNS_FOR_TEST.filter(Boolean));
    expect(seen.size).toBe(PATTERNS_FOR_TEST.filter(Boolean).length);
  });

  it('ends in the 13-module stop pattern and begins with the start B pattern', () => {
    const w = code128bWidths('CH-2026-0001');
    expect(w.slice(0, 6).join('')).toBe('211214');
    expect(w.slice(-7).join('')).toBe('2331112');
    expect(w.slice(-7).reduce((a, b) => a + b, 0)).toBe(13);
  });

  it('is 11 modules per character plus start, checksum and stop', () => {
    const text = 'CH-2026-0001';
    expect(code128bModules(text)).toBe(11 * (text.length + 2) + 13);
  });

  it('refuses what subset B cannot carry', () => {
    expect(() => code128bValues('')).toThrow(BarcodeError);
    expect(() => code128bValues('é')).toThrow(BarcodeError);
    expect(() => code128bValues('a\nb')).toThrow(BarcodeError);
  });
});

describe('code128bSvg', () => {
  it('is deterministic and self-contained', () => {
    const a = code128bSvg('CH-2026-0001');
    expect(a).toBe(code128bSvg('CH-2026-0001'));
    expect(a.startsWith('<svg')).toBe(true);
    expect(a).toContain('aria-label="Barcode CH-2026-0001"');
    expect(a).not.toContain('<script');
  });

  it('draws one rect per bar, leaving the quiet zones empty', () => {
    const svg = code128bSvg('A', { moduleWidth: 2 });
    const bars = svg.match(/<rect /g) ?? [];
    // start(3) + A(3) + checksum(3) + stop(4 bars)
    expect(bars).toHaveLength(13);
    expect(svg).toContain('<rect x="20"');
  });

  it('escapes the label', () => {
    expect(code128bSvg('A"B')).toContain('A&#34;B');
  });
});
