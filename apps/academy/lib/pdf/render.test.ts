import { describe, expect, it } from 'vitest';
import { embeddedFontNames, isPdf, pdfPageCount, stampPdfTimestamps } from './render';

/**
 * FR-J09. stampPdfTimestamps() is what makes a report card's checksum a
 * statement about the document rather than about the minute it was produced,
 * so the property that matters is that it rewrites both dates, leaves the
 * length untouched, and refuses to touch anything it does not recognise.
 */
const skiaHeader = (created: string, modified: string) =>
  `%PDF-1.4\n1 0 obj\n<</Producer (Skia/PDF m151)\n/CreationDate (${created})\n/ModDate (${modified})>>\nendobj\n`;

const latin1 = (s: string) => new Uint8Array(Buffer.from(s, 'latin1'));
const str = (b: Uint8Array) => Buffer.from(b).toString('latin1');

describe('stampPdfTimestamps', () => {
  const at = new Date(Date.UTC(2026, 5, 30, 9, 5, 7));

  it('rewrites both dates to the given instant', () => {
    const out = str(stampPdfTimestamps(latin1(skiaHeader("D:20260813231310+00'00'", "D:20260813231311+00'00'")), at));
    expect(out).toContain("/CreationDate (D:20260630090507+00'00')");
    expect(out).toContain("/ModDate (D:20260630090507+00'00')");
  });

  it('makes two renders taken a second apart byte-identical', () => {
    const first = stampPdfTimestamps(latin1(skiaHeader("D:20260813231310+00'00'", "D:20260813231310+00'00'")), at);
    const second = stampPdfTimestamps(latin1(skiaHeader("D:20260813231311+00'00'", "D:20260813231311+00'00'")), at);
    expect(str(first)).toBe(str(second));
  });

  it('preserves the byte length, because the xref table indexes into it', () => {
    const input = latin1(skiaHeader("D:20260813231310+00'00'", "D:20260813231310+00'00'"));
    expect(stampPdfTimestamps(input, at).length).toBe(input.length);
  });

  it('leaves a date it does not recognise alone rather than shortening the file', () => {
    const odd = skiaHeader('20260813', '20260813');
    expect(str(stampPdfTimestamps(latin1(odd), at))).toBe(odd);
  });

  it('is idempotent', () => {
    const once = stampPdfTimestamps(latin1(skiaHeader("D:20260813231310+00'00'", "D:20260813231310+00'00'")), at);
    expect(str(stampPdfTimestamps(once, at))).toBe(str(once));
  });

  it('leaves the rest of the document untouched', () => {
    const out = str(stampPdfTimestamps(latin1(skiaHeader("D:20260813231310+00'00'", "D:20260813231310+00'00'")), at));
    expect(isPdf(latin1(out))).toBe(true);
    expect(out).toContain('/Producer (Skia/PDF m151)');
  });
});

describe('pdf byte readers', () => {
  it('counts only page objects, not the page tree node', () => {
    expect(pdfPageCount(latin1('/Type /Pages\n/Type /Page\n/Type /Page\n'))).toBe(2);
  });

  it('strips the subset prefix off an embedded font name', () => {
    expect(embeddedFontNames(latin1('/BaseFont /ABCDEF+NotoNastaliqUrdu'))).toEqual(['NotoNastaliqUrdu']);
  });

  it('rejects bytes that are not a PDF', () => {
    expect(isPdf(latin1('<html>'))).toBe(false);
  });
});
