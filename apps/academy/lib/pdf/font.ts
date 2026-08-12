import { existsSync, readFileSync } from 'node:fs';

/**
 * FR-F15 AC4: "subject names print in Urdu with an embedded Nastaliq font
 * and a rendering check confirms zero missing glyphs".
 *
 * The rendering check is a real cmap lookup, not an assumption: every
 * Arabic-script codepoint that is about to be printed is looked up in the
 * actual font file's character map before the page is rendered, and the
 * count of misses is stored on the export job. A codepoint the font cannot
 * map is a tofu box on a noticeboard sheet, which is exactly the failure
 * this AC exists to catch.
 *
 * Nastaliq's joining and ligature behaviour lives in the font's GSUB
 * table, which the shaper (HarfBuzz, inside Chromium) applies at render
 * time; cmap coverage of the base codepoints is the precondition for any
 * of that to happen, and is the part that can be verified without a
 * shaper.
 */

export const NASTALIQ_FONT_FAMILY = 'Noto Nastaliq Urdu';

/**
 * No font binary is committed to this repo (a ~500KB blob, and the OFL
 * copy on any given machine is packaged differently). The font is resolved
 * from the render host instead: an explicit env override first, then the
 * standard locations the OFL Noto Nastaliq Urdu build lands in on macOS
 * and on Debian/Ubuntu (fonts-noto-core).
 */
const SYSTEM_FONT_PATHS = [
  '/System/Library/Fonts/NotoNastaliq.ttc',
  '/Library/Fonts/NotoNastaliqUrdu-Regular.ttf',
  '/usr/share/fonts/truetype/noto/NotoNastaliqUrdu-Regular.ttf',
  '/usr/share/fonts/opentype/noto/NotoNastaliqUrdu-Regular.ttf',
  '/usr/share/fonts/truetype/noto/NotoNastaliqUrdu.ttf',
];

export type CodepointRange = readonly [number, number];

export type ResolvedFont = {
  path: string;
  bytes: Buffer;
  /** A .ttc holds several faces and cannot be inlined via @font-face. */
  isCollection: boolean;
};

export function resolveNastaliqFont(): ResolvedFont | null {
  const override = process.env.ACADEMY_NASTALIQ_FONT_PATH;
  const candidates = override ? [override, ...SYSTEM_FONT_PATHS] : SYSTEM_FONT_PATHS;
  for (const path of candidates) {
    if (!existsSync(path)) continue;
    const bytes = readFileSync(path);
    return { path, bytes, isCollection: bytes.length >= 4 && bytes.toString('latin1', 0, 4) === 'ttcf' };
  }
  return null;
}

function u16(b: Uint8Array, at: number): number {
  if (at + 2 > b.length) throw new Error(`font: read past end at ${at}`);
  return (b[at]! << 8) | b[at + 1]!;
}

function i16(b: Uint8Array, at: number): number {
  const v = u16(b, at);
  return v >= 0x8000 ? v - 0x10000 : v;
}

function u32(b: Uint8Array, at: number): number {
  if (at + 4 > b.length) throw new Error(`font: read past end at ${at}`);
  return ((b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;
}

function tag(b: Uint8Array, at: number): string {
  return String.fromCharCode(b[at]!, b[at + 1]!, b[at + 2]!, b[at + 3]!);
}

function sfntOffsets(bytes: Uint8Array): number[] {
  if (tag(bytes, 0) === 'ttcf') {
    const numFonts = u32(bytes, 8);
    return Array.from({ length: numFonts }, (_, i) => u32(bytes, 12 + i * 4));
  }
  return [0];
}

function cmapTableOffset(bytes: Uint8Array, fontOffset: number): number | null {
  const numTables = u16(bytes, fontOffset + 4);
  for (let i = 0; i < numTables; i += 1) {
    const entry = fontOffset + 12 + i * 16;
    if (tag(bytes, entry) === 'cmap') return u32(bytes, entry + 8);
  }
  return null;
}

function readFormat4(bytes: Uint8Array, at: number, out: Array<[number, number]>): void {
  const segCount = u16(bytes, at + 6) / 2;
  const endAt = at + 14;
  const startAt = endAt + segCount * 2 + 2;
  const deltaAt = startAt + segCount * 2;
  const rangeOffsetAt = deltaAt + segCount * 2;

  for (let seg = 0; seg < segCount; seg += 1) {
    const end = u16(bytes, endAt + seg * 2);
    const start = u16(bytes, startAt + seg * 2);
    if (start > end || start === 0xffff) continue;
    const delta = i16(bytes, deltaAt + seg * 2);
    const rangeOffset = u16(bytes, rangeOffsetAt + seg * 2);

    let runStart: number | null = null;
    for (let cp = start; cp <= end; cp += 1) {
      let glyph: number;
      if (rangeOffset === 0) {
        glyph = (cp + delta) & 0xffff;
      } else {
        const glyphAt = rangeOffsetAt + seg * 2 + rangeOffset + (cp - start) * 2;
        glyph = glyphAt + 2 <= bytes.length ? u16(bytes, glyphAt) : 0;
        if (glyph !== 0) glyph = (glyph + delta) & 0xffff;
      }
      if (glyph !== 0) {
        if (runStart === null) runStart = cp;
      } else if (runStart !== null) {
        out.push([runStart, cp - 1]);
        runStart = null;
      }
    }
    if (runStart !== null) out.push([runStart, end]);
  }
}

function readFormat12(bytes: Uint8Array, at: number, out: Array<[number, number]>): void {
  const nGroups = u32(bytes, at + 12);
  for (let g = 0; g < nGroups; g += 1) {
    const group = at + 16 + g * 12;
    const start = u32(bytes, group);
    const end = u32(bytes, group + 4);
    const startGlyph = u32(bytes, group + 8);
    if (startGlyph !== 0 && end >= start) out.push([start, end]);
  }
}

function coalesce(ranges: Array<[number, number]>): CodepointRange[] {
  if (ranges.length === 0) return [];
  const sorted = [...ranges].sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const merged: Array<[number, number]> = [sorted[0]!];
  for (const [start, end] of sorted.slice(1)) {
    const last = merged[merged.length - 1]!;
    if (start <= last[1] + 1) last[1] = Math.max(last[1], end);
    else merged.push([start, end]);
  }
  return merged;
}

/**
 * Every codepoint the font can map, as merged ranges. Reads every format-4
 * and format-12 subtable of every face in the file (a .ttc holds several)
 * and unions them — picking a "best" subtable would only ever narrow what
 * is genuinely renderable.
 */
export function parseCmapRanges(bytes: Uint8Array): CodepointRange[] {
  const out: Array<[number, number]> = [];
  for (const fontOffset of sfntOffsets(bytes)) {
    const cmapAt = cmapTableOffset(bytes, fontOffset);
    if (cmapAt === null) continue;
    const numSubtables = u16(bytes, cmapAt + 2);
    for (let i = 0; i < numSubtables; i += 1) {
      const subtableAt = cmapAt + u32(bytes, cmapAt + 4 + i * 8 + 4);
      const format = u16(bytes, subtableAt);
      if (format === 4) readFormat4(bytes, subtableAt, out);
      else if (format === 12) readFormat12(bytes, subtableAt, out);
    }
  }
  return coalesce(out);
}

export function hasCodepoint(ranges: readonly CodepointRange[], cp: number): boolean {
  let lo = 0;
  let hi = ranges.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const range = ranges[mid]!;
    if (cp < range[0]) hi = mid - 1;
    else if (cp > range[1]) lo = mid + 1;
    else return true;
  }
  return false;
}

/**
 * Only Arabic-script codepoints are the Nastaliq font's responsibility —
 * Latin letters, digits and punctuation in a mixed string render from the
 * document's Latin font, so flagging them as "missing from the Nastaliq
 * font" would be a false alarm, not a finding.
 */
export function isUrduScriptCodepoint(cp: number): boolean {
  return (
    (cp >= 0x0600 && cp <= 0x06ff) || // Arabic
    (cp >= 0x0750 && cp <= 0x077f) || // Arabic Supplement
    (cp >= 0x08a0 && cp <= 0x08ff) || // Arabic Extended-A
    (cp >= 0xfb50 && cp <= 0xfdff) || // Arabic Presentation Forms-A
    (cp >= 0xfe70 && cp <= 0xfeff) // Arabic Presentation Forms-B
  );
}

export type GlyphCoverageReport = {
  checkedCodepoints: number;
  missing: string[];
};

export function checkGlyphCoverage(strings: readonly (string | null | undefined)[], ranges: readonly CodepointRange[]): GlyphCoverageReport {
  const wanted = new Set<number>();
  for (const s of strings) {
    if (!s) continue;
    for (const ch of s) {
      const cp = ch.codePointAt(0)!;
      if (isUrduScriptCodepoint(cp)) wanted.add(cp);
    }
  }
  const missing: string[] = [];
  for (const cp of [...wanted].sort((a, b) => a - b)) {
    if (!hasCodepoint(ranges, cp)) missing.push(`U+${cp.toString(16).toUpperCase().padStart(4, '0')}`);
  }
  return { checkedCodepoints: wanted.size, missing };
}

/**
 * A single-face file is inlined as a data: URI so the rendered PDF embeds
 * the exact bytes the coverage check just validated, on any host. A .ttc
 * cannot be inlined (CSS `format('collection')` is not reliably supported),
 * so on those hosts the family name is referenced and the OS-installed
 * face is used — still embedded (subset) into the PDF by Chromium, just
 * resolved by name rather than by URL.
 */
export function nastaliqFontFaceCss(font: ResolvedFont | null): string {
  if (!font || font.isCollection) return '';
  const format = font.bytes.toString('latin1', 0, 4) === 'OTTO' ? 'opentype' : 'truetype';
  return `@font-face { font-family: '${NASTALIQ_FONT_FAMILY}'; src: url(data:font/${format === 'opentype' ? 'otf' : 'ttf'};base64,${font.bytes.toString('base64')}) format('${format}'); font-display: block; }`;
}
