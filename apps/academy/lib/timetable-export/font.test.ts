import { describe, expect, it } from 'vitest';
import { checkGlyphCoverage, hasCodepoint, isUrduScriptCodepoint, parseCmapRanges } from './font';

/**
 * A real Nastaliq binary is deliberately not committed (see font.ts), so
 * the cmap parser is exercised against fonts synthesised right here: a
 * minimal but structurally valid sfnt carrying exactly the subtable under
 * test. That keeps the test hermetic and lets it assert on codepoints that
 * are known-present and known-absent, which a real font never lets you do.
 */

function u16(v: number): number[] {
  return [(v >> 8) & 0xff, v & 0xff];
}

function u32(v: number): number[] {
  return [(v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff];
}

type Segment = { start: number; end: number; delta: number };

function format4Subtable(segments: Segment[]): number[] {
  // The 0xFFFF terminator segment every format-4 table must end with.
  const segs = [...segments, { start: 0xffff, end: 0xffff, delta: 1 }];
  const segCount = segs.length;
  const body = [
    ...u16(4), // format
    ...u16(16 + segCount * 8), // length
    ...u16(0), // language
    ...u16(segCount * 2),
    ...u16(0), // searchRange (unused by the parser)
    ...u16(0), // entrySelector
    ...u16(0), // rangeShift
    ...segs.flatMap((s) => u16(s.end)),
    ...u16(0), // reservedPad
    ...segs.flatMap((s) => u16(s.start)),
    ...segs.flatMap((s) => u16(s.delta & 0xffff)),
    ...segs.flatMap(() => u16(0)), // idRangeOffset — all direct-delta
  ];
  return body;
}

function format12Subtable(groups: Array<{ start: number; end: number; startGlyph: number }>): number[] {
  return [
    ...u16(12),
    ...u16(0),
    ...u32(16 + groups.length * 12),
    ...u32(0),
    ...u32(groups.length),
    ...groups.flatMap((g) => [...u32(g.start), ...u32(g.end), ...u32(g.startGlyph)]),
  ];
}

function sfntWithCmap(subtables: number[][]): Uint8Array {
  const recordCount = subtables.length;
  const cmapHeaderLength = 4 + recordCount * 8;
  const offsets: number[] = [];
  let running = cmapHeaderLength;
  for (const st of subtables) {
    offsets.push(running);
    running += st.length;
  }
  const cmap = [
    ...u16(0),
    ...u16(recordCount),
    ...subtables.flatMap((_, i) => [...u16(3), ...u16(i === 0 ? 1 : 10), ...u32(offsets[i]!)]),
    ...subtables.flat(),
  ];

  const sfntHeader = [...u32(0x00010000), ...u16(1), ...u16(0), ...u16(0), ...u16(0)];
  const cmapOffset = sfntHeader.length + 16;
  const table = [...'cmap'].map((c) => c.charCodeAt(0));
  return Uint8Array.from([...sfntHeader, ...table, ...u32(0), ...u32(cmapOffset), ...u32(cmap.length), ...cmap]);
}

function ttcOf(fonts: Uint8Array[]): Uint8Array {
  // A TTC's font offsets are absolute, so each embedded sfnt has to be
  // rewritten with its cmap offset shifted by where it lands. The fixture
  // sidesteps that by giving every face the same single-table layout and
  // patching the one offset field.
  const headerLength = 12 + fonts.length * 4;
  const offsets: number[] = [];
  let running = headerLength;
  const bodies: Uint8Array[] = [];
  for (const font of fonts) {
    offsets.push(running);
    const copy = Uint8Array.from(font);
    const view = new DataView(copy.buffer, copy.byteOffset, copy.byteLength);
    view.setUint32(12 + 8, view.getUint32(12 + 8) + running); // cmap table offset
    bodies.push(copy);
    running += copy.length;
  }
  const out = new Uint8Array(running);
  out.set(Uint8Array.from([...[...'ttcf'].map((c) => c.charCodeAt(0)), ...u32(0x00010000), ...u32(fonts.length), ...offsets.flatMap(u32)]));
  bodies.forEach((b, i) => out.set(b, offsets[i]!));
  return out;
}

describe('parseCmapRanges', () => {
  it('reads a format-4 subtable and merges adjacent segments', () => {
    const font = sfntWithCmap([format4Subtable([{ start: 0x0600, end: 0x06ff, delta: 1 }, { start: 0x0700, end: 0x0710, delta: 1 }])]);
    expect(parseCmapRanges(font)).toEqual([[0x0600, 0x0710]]);
  });

  it('excludes codepoints a format-4 segment maps to glyph 0', () => {
    // delta chosen so 0x0605 maps to glyph 0 — a mapped-to-notdef hole.
    const font = sfntWithCmap([format4Subtable([{ start: 0x0600, end: 0x060a, delta: -0x0605 }])]);
    const ranges = parseCmapRanges(font);
    expect(ranges).toEqual([
      [0x0600, 0x0604],
      [0x0606, 0x060a],
    ]);
  });

  it('reads a format-12 subtable', () => {
    const font = sfntWithCmap([
      format4Subtable([{ start: 0x0041, end: 0x005a, delta: 1 }]),
      format12Subtable([{ start: 0x1ee00, end: 0x1ee0f, startGlyph: 5 }]),
    ]);
    const ranges = parseCmapRanges(font);
    expect(hasCodepoint(ranges, 0x0041)).toBe(true);
    expect(hasCodepoint(ranges, 0x1ee05)).toBe(true);
    expect(hasCodepoint(ranges, 0x1ee10)).toBe(false);
  });

  it('unions every face of a font collection', () => {
    const arabic = sfntWithCmap([format4Subtable([{ start: 0x0620, end: 0x0640, delta: 1 }])]);
    const latin = sfntWithCmap([format4Subtable([{ start: 0x0041, end: 0x005a, delta: 1 }])]);
    const ranges = parseCmapRanges(ttcOf([arabic, latin]));
    expect(hasCodepoint(ranges, 0x0630)).toBe(true);
    expect(hasCodepoint(ranges, 0x0050)).toBe(true);
  });
});

describe('isUrduScriptCodepoint', () => {
  it('claims the Arabic blocks and nothing else', () => {
    expect(isUrduScriptCodepoint(0x06a9)).toBe(true); // ک
    expect(isUrduScriptCodepoint(0xfefb)).toBe(true); // lam-alef ligature
    expect(isUrduScriptCodepoint(0x0041)).toBe(false); // A
    expect(isUrduScriptCodepoint(0x0031)).toBe(false); // 1
    expect(isUrduScriptCodepoint(0x0020)).toBe(false);
  });
});

describe('checkGlyphCoverage', () => {
  const ranges = parseCmapRanges(sfntWithCmap([format4Subtable([{ start: 0x0600, end: 0x06ff, delta: 1 }])]));

  it('AC4: reports zero missing glyphs when every Urdu codepoint is mapped', () => {
    const report = checkGlyphCoverage(['اسلامیات', 'ریاضی', 'فزکس'], ranges);
    expect(report.missing).toEqual([]);
    expect(report.checkedCodepoints).toBeGreaterThan(0);
  });

  it('names the codepoints the font cannot map', () => {
    // U+0768 (Arabic Supplement) sits outside the fixture font's coverage.
    const report = checkGlyphCoverage(['ریاضیݨ'], ranges);
    expect(report.missing).toEqual(['U+0768']);
  });

  it('ignores Latin, digits and whitespace — the Latin font renders those', () => {
    const report = checkGlyphCoverage(['Physics 9-A', null, undefined, '   '], ranges);
    expect(report).toEqual({ checkedCodepoints: 0, missing: [] });
  });

  it('counts each distinct codepoint once, however often it repeats', () => {
    const report = checkGlyphCoverage(['ااااا', 'ا'], ranges);
    expect(report.checkedCodepoints).toBe(1);
  });
});
