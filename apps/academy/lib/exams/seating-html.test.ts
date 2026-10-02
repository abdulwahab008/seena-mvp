import { describe, expect, it } from 'vitest';
import { buildSeatingChartHtml, buildSeatSlipsHtml, collectSeatingStrings, type SeatAllocation, type SeatingChart } from './seating-html';

const alloc = (over: Partial<SeatAllocation>): SeatAllocation => ({
  row_no: 1,
  seat_no: 1,
  label: 'R1-S1',
  set_code: 'A',
  gr_number: 'GR-0001',
  name_en: 'Ali Raza',
  name_ur: 'علی رضا',
  section_name: 'A',
  section_id: 'sec-a',
  roll_no: 1,
  ...over,
});

const chart = (over: Partial<SeatingChart> = {}): SeatingChart => ({
  slot_id: 'slot-1',
  start_at: '2026-09-08T04:00:00Z',
  end_at: '2026-09-08T06:00:00Z',
  class_name: 'Class 9',
  subject_name_en: 'Physics',
  subject_name_ur: 'طبیعیات',
  hall: { id: 'h1', name: 'Main Hall', code: 'H1', rows: 2, seats_per_row: 3 },
  set_count: 2,
  timezone: 'Asia/Karachi',
  allocations: [alloc({}), alloc({ seat_no: 2, label: 'R1-S2', set_code: 'B', gr_number: 'GR-0002', name_en: 'Sara Khan', section_name: 'B', section_id: 'sec-b' })],
  ...over,
});

describe('seat slips', () => {
  it('print the set letter of the seat on every slip (AC3)', () => {
    const { html } = buildSeatSlipsHtml(chart(), null);
    expect(html).toContain('data-set="A">Set A');
    expect(html).toContain('data-set="B">Set B');
    expect(html.match(/class="slip"/g)).toHaveLength(2);
  });

  it('carry the hall, the seat label, the section and the local paper time', () => {
    const { html } = buildSeatSlipsHtml(chart(), null);
    expect(html).toContain('Main Hall');
    expect(html).toContain('Seat R1-S2');
    expect(html).toContain('Section B');
    expect(html).toContain('09:00 – 11:00');
  });

  it('print the Urdu name and subject in the Nastaliq family', () => {
    const { html } = buildSeatSlipsHtml(chart(), null);
    expect(html).toContain('علی رضا');
    expect(html).toContain('طبیعیات');
    expect(html).toContain("font-family: 'Noto Nastaliq Urdu'");
  });

  it('escapes names', () => {
    const { html } = buildSeatSlipsHtml(chart({ allocations: [alloc({ name_en: '<img src=x>' })] }), null);
    expect(html).not.toContain('<img src=x>');
  });
});

describe('seating chart', () => {
  it('draws every seat of the hall and leaves unallocated seats empty', () => {
    const { html } = buildSeatingChartHtml(chart(), null);
    expect(html.match(/<tr><th>R\d+<\/th>/g)).toHaveLength(2);
    expect(html.match(/class="empty"/g)).toHaveLength(4);
    expect(html).toContain('GR-0002');
  });

  it('shows the set only when the paper has several sets', () => {
    expect(buildSeatingChartHtml(chart(), null).html).toContain('Set B');
    expect(buildSeatingChartHtml(chart({ set_count: 1 }), null).html).not.toContain('· Set');
  });

  it('colours each section differently and lists them in the legend', () => {
    const { html } = buildSeatingChartHtml(chart(), null);
    expect(html).toContain('Section A');
    expect(html).toContain('Section B');
    expect(new Set(html.match(/background:#[0-9a-f]{6}/g)).size).toBe(2);
  });

  it('says so when no hall is assigned', () => {
    expect(buildSeatingChartHtml(chart({ hall: null }), null).html).toContain('No hall is assigned');
  });

  it('collects the names that will be typeset for the glyph check', () => {
    expect(collectSeatingStrings(chart())).toEqual(expect.arrayContaining(['علی رضا', 'Ali Raza', 'طبیعیات']));
  });
});
