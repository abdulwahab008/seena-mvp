import { describe, expect, it } from 'vitest';
import { buildDatesheetHtml, collectDatesheetStrings, type DatesheetPdfPayload, type DatesheetPdfRow } from './html';
import { checkGlyphCoverage, parseCmapRanges, resolveNastaliqFont } from '@/lib/pdf/font';

const row = (over: Partial<DatesheetPdfRow> = {}): DatesheetPdfRow => ({
  class_name: 'Class 9',
  subject_name_en: 'Physics',
  subject_name_ur: 'طبیعیات',
  start_at: '2026-09-08T04:00:00Z',
  end_at: '2026-09-08T06:00:00Z',
  hall_name: 'Main Hall',
  change_kind: 'new',
  previous_start_at: null,
  ...over,
});

const payload = (over: Partial<DatesheetPdfPayload> = {}): DatesheetPdfPayload => ({
  campusName: 'Seena Main Campus',
  title: 'First Term datesheet',
  versionNo: 1,
  publishedAt: '2026-08-30T05:00:00Z',
  note: null,
  timezone: 'Asia/Karachi',
  rows: [row()],
  ...over,
});

describe('buildDatesheetHtml', () => {
  it('prints every subject in English and in Urdu (AC4)', () => {
    const { html } = buildDatesheetHtml(payload(), null);
    expect(html).toContain('<span class="en">Physics</span>');
    expect(html).toContain('<span class="ur">طبیعیات</span>');
  });

  it('typesets the Urdu in the Nastaliq family and embeds the face when one is available (AC4)', () => {
    const font = { path: '/x.ttf', bytes: Buffer.from('\0\x01\0\0fontbytes', 'latin1'), isCollection: false };
    const { html } = buildDatesheetHtml(payload(), font);
    expect(html).toContain("font-family: 'Noto Nastaliq Urdu'");
    expect(html).toContain('@font-face');
    expect(html).toContain(font.bytes.toString('base64'));
  });

  it('shows 9:00 local time for a 04:00Z paper at a campus in Asia/Karachi', () => {
    expect(buildDatesheetHtml(payload(), null).html).toContain('09:00 – 11:00');
  });

  it('has no revised banner on version 1 and does not highlight rows', () => {
    const { html } = buildDatesheetHtml(payload(), null);
    expect(html).not.toContain('data-revised');
    expect(html).not.toContain('class="changed"');
  });

  it('puts a revised banner on version 2 and highlights only the changed rows', () => {
    const { html } = buildDatesheetHtml(
      payload({
        versionNo: 2,
        note: 'Rain delay.',
        rows: [row({ subject_name_en: 'Chemistry', change_kind: 'unchanged' }), row({ change_kind: 'moved', previous_start_at: '2026-09-07T04:00:00Z' })],
      }),
      null,
    );
    expect(html).toContain('REVISED — version 2');
    expect(html).toContain('Rain delay.');
    expect(html.match(/<tr class="changed">/g)).toHaveLength(1);
    expect(html).toMatch(/was \w+,? 07 \w+ 2026/);
  });

  it('escapes markup in names', () => {
    const { html } = buildDatesheetHtml(payload({ rows: [row({ subject_name_en: '<b>x</b>' })] }), null);
    expect(html).not.toContain('<b>x</b>');
    expect(html).toContain('&lt;b&gt;x&lt;/b&gt;');
  });

  it('groups papers by class in date order', () => {
    const { html } = buildDatesheetHtml(
      payload({ rows: [row({ class_name: 'Class 10', subject_name_en: 'Biology' }), row({ subject_name_en: 'Later', start_at: '2026-09-10T04:00:00Z' }), row({ subject_name_en: 'Earlier' })] }),
      null,
    );
    expect(html.indexOf('Class 9')).toBeLessThan(html.indexOf('Class 10'));
    expect(html.indexOf('Earlier')).toBeLessThan(html.indexOf('Later'));
  });
});

describe('Urdu glyph coverage', () => {
  it('collects the Urdu and English names that will be typeset', () => {
    expect(collectDatesheetStrings(payload())).toEqual(expect.arrayContaining(['طبیعیات', 'Physics']));
  });

  // Only meaningful on a host with the Nastaliq face installed; the check itself is the same cmap lookup
  // the timetable export runs.
  it.skipIf(!resolveNastaliqFont())('finds no missing glyph for the subject names in the installed font', () => {
    const font = resolveNastaliqFont()!;
    const report = checkGlyphCoverage(collectDatesheetStrings(payload()), parseCmapRanges(font.bytes));
    expect(report.missing).toEqual([]);
  });
});
