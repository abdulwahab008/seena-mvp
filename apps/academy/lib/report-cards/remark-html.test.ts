import { describe, expect, it } from 'vitest';
import { checkGlyphCoverage } from '@/lib/pdf/font';
import { remarkDirection, remarkMarkup } from './html';

// FR-J10 AC3. The trap is Urdu in the PDF, so these use a mixed
// English/Urdu string containing digits, not pure Urdu.
const MIXED_URDU_MAJORITY = 'طالب علم کی کارکردگی 85% بہتر ہے, Grade A';
const MIXED_ENGLISH_MAJORITY = 'Ali has worked very hard this term and scored 85% overall, ماشاء اللہ';

describe('remarkMarkup (FR-J10 AC3)', () => {
  it('leaves an English remark exactly as before', () => {
    expect(remarkMarkup('A steady term.')).toBe('<div data-remark>A steady term.</div>');
    expect(remarkMarkup(null)).toBe('<div data-remark></div>');
  });

  it('lays a pure Urdu remark out right-to-left in the embedded Nastaliq class', () => {
    const html = remarkMarkup('محنتی اور باادب طالب علم');
    expect(html).toContain('class="urdu"');
    expect(html).toContain('dir="rtl"');
    expect(html).toContain('lang="ur"');
  });

  it('treats a mixed string with digits and Latin words as RTL when Urdu dominates, keeping the digits as written', () => {
    expect(remarkDirection(MIXED_URDU_MAJORITY)).toBe('rtl');
    const html = remarkMarkup(MIXED_URDU_MAJORITY);
    expect(html).toContain('dir="rtl"');
    expect(html).toContain('85%');
    expect(html).toContain('Grade A');
    expect(html).not.toMatch(/[٠-٩۰-۹]/);
  });

  it('keeps an English-majority remark LTR and isolates the Urdu run as an RTL Nastaliq span', () => {
    expect(remarkDirection(MIXED_ENGLISH_MAJORITY)).toBe('ltr');
    const html = remarkMarkup(MIXED_ENGLISH_MAJORITY);
    expect(html).toContain('<div data-remark dir="ltr" lang="en">');
    expect(html).toContain('<span class="urdu" dir="rtl" lang="ur">ماشاء اللہ</span>');
    expect(html).toContain('85%');
  });

  it('escapes markup in every mode', () => {
    expect(remarkMarkup('<b>x</b> طالب')).toContain('&lt;b&gt;');
    expect(remarkMarkup('<script>1</script>')).not.toContain('<script>');
    expect(remarkMarkup('<i>ہے</i> ہے ہے ہے')).not.toContain('<i>');
  });
});

describe('glyph coverage for a mixed remark', () => {
  it('only asks the Nastaliq font for Arabic-script codepoints, never for the digits or Latin letters', () => {
    // A font covering only the basic Arabic block 0x0600-0x06FF.
    const report = checkGlyphCoverage([MIXED_URDU_MAJORITY], [[0x0600, 0x06ff]]);
    expect(report.missing).toEqual([]);
    expect(report.checkedCodepoints).toBeGreaterThan(5);
  });

  it('reports a codepoint the font cannot map', () => {
    const report = checkGlyphCoverage([MIXED_URDU_MAJORITY], [[0x0600, 0x0640]]);
    expect(report.missing.length).toBeGreaterThan(0);
  });
});
