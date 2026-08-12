import { describe, expect, it } from 'vitest';
import {
  SCHOOL_WEEKDAYS,
  buildMasterPages,
  buildSectionSheets,
  buildTeacherSheets,
  collectUrduStrings,
  formatPeriodTime,
  masterGridMetrics,
  pageCountFor,
  resolvePeriods,
  sectionLabel,
  sheetGridMetrics,
  type ExportLayout,
  type ExportPayload,
  type PayloadSlot,
} from './layout';
import { buildExportHtml } from './html';
import { embeddedFontNames, isPdf, pdfPageCount } from './pdf';

function section(id: string, name: string, ordinal = 1, medium: 'ENGLISH' | 'URDU' = 'ENGLISH') {
  return {
    id,
    name,
    medium,
    class_level_name_en: `Class ${ordinal}`,
    class_level_name_ur: 'جماعت',
    class_level_ordinal: ordinal,
  };
}

function slot(over: Partial<PayloadSlot> & Pick<PayloadSlot, 'section_id' | 'weekday' | 'period_no'>): PayloadSlot {
  return {
    subject_code: 'PHY',
    subject_name_en: 'Physics',
    subject_name_ur: 'فزکس',
    staff_id: 'staff-1',
    teacher_name: 'Ms Ayesha',
    room_code: 'R1',
    elective_bucket: null,
    ...over,
  };
}

function payload(over: Partial<ExportPayload> = {}, layout: ExportLayout = 'section'): ExportPayload {
  return {
    job: { id: 'job-1', layout, scope_staff_id: null, scope_section_ids: null, ...(over.job ?? {}) },
    tenant: { name: 'Seena School', name_ur: 'سینا اسکول' },
    campus: { id: 'campus-1', code: 'GUL', name: 'Gulberg', name_ur: null },
    session: { id: 'session-1', name: '2026-27' },
    version: {
      id: 'version-1',
      name: 'Term 1',
      version_no: 3,
      status: 'PUBLISHED',
      shift: 'MORNING',
      effective_from: '2026-08-01',
      effective_to: null,
    },
    logo_storage_path: null,
    periods: [
      { period_no: 1, start_time: '08:00:00', end_time: '08:40:00' },
      { period_no: 2, start_time: '08:40:00', end_time: '09:20:00' },
    ],
    sections: [section('sec-a', 'A'), section('sec-b', 'B')],
    slots: [slot({ section_id: 'sec-a', weekday: 1, period_no: 1 })],
    teachers: [{ id: 'staff-1', name: 'Ms Ayesha' }],
    ...over,
  };
}

describe('resolvePeriods', () => {
  it('unions the bell template periods with any period a slot actually uses', () => {
    const p = payload({ slots: [slot({ section_id: 'sec-a', weekday: 1, period_no: 7 })] });
    expect(resolvePeriods(p).map((x) => x.period_no)).toEqual([1, 2, 7]);
  });

  it('leaves a period with no bell times untimed rather than inventing them', () => {
    const p = payload({ slots: [slot({ section_id: 'sec-a', weekday: 1, period_no: 7 })] });
    const seventh = resolvePeriods(p).find((x) => x.period_no === 7)!;
    expect(formatPeriodTime(seventh)).toBe('');
    expect(formatPeriodTime(resolvePeriods(p)[0]!)).toBe('08:00–08:40');
  });
});

describe('buildSectionSheets', () => {
  it('produces one sheet per section, each a full period × weekday grid', () => {
    const sheets = buildSectionSheets(payload());
    expect(sheets).toHaveLength(2);
    expect(sheets.map((s) => s.title)).toEqual(['Class 1 A', 'Class 1 B']);
    expect(sheets[0]!.rows).toHaveLength(2);
    expect(sheets[0]!.rows[0]!.cells).toHaveLength(SCHOOL_WEEKDAYS.length);
  });

  it('places a slot in its own weekday/period cell and leaves the rest free', () => {
    const [sheetA] = buildSectionSheets(payload());
    const mondayPeriod1 = sheetA!.rows[0]!.cells[0];
    expect(mondayPeriod1?.subject_code).toBe('PHY');
    expect(sheetA!.rows[0]!.cells[1]).toBeNull();
    expect(sheetA!.rows[1]!.cells[0]).toBeNull();
  });

  it('never leaks another section’s slot onto a sheet', () => {
    const sheets = buildSectionSheets(payload());
    expect(sheets[1]!.rows.flatMap((r) => r.cells).filter(Boolean)).toHaveLength(0);
  });
});

describe('buildTeacherSheets', () => {
  it('AC2: one sheet per teacher, ordered by name', () => {
    const p = payload(
      {
        teachers: [
          { id: 'staff-2', name: 'Mr Bilal' },
          { id: 'staff-1', name: 'Ms Ayesha' },
        ],
        slots: [
          slot({ section_id: 'sec-a', weekday: 1, period_no: 1, staff_id: 'staff-1' }),
          slot({ section_id: 'sec-b', weekday: 2, period_no: 2, staff_id: 'staff-2' }),
        ],
      },
      'teacher',
    );
    const sheets = buildTeacherSheets(p);
    expect(sheets.map((s) => s.title)).toEqual(['Mr Bilal', 'Ms Ayesha']);
    expect(sheets[0]!.rows[1]!.cells[1]?.section_id).toBe('sec-b');
    expect(sheets[0]!.rows[0]!.cells[0]).toBeNull();
  });

  it('AC6: a payload scoped to one teacher yields exactly one sheet', () => {
    const p = payload(
      {
        job: { id: 'job-1', layout: 'teacher', scope_staff_id: 'staff-1', scope_section_ids: null },
        teachers: [{ id: 'staff-1', name: 'Ms Ayesha' }],
      },
      'teacher',
    );
    expect(buildTeacherSheets(p)).toHaveLength(1);
    expect(pageCountFor(p)).toBe(1);
  });

  it('still gives a teacher with no scheduled periods her own, entirely free page', () => {
    const p = payload({ slots: [], job: { id: 'job-1', layout: 'teacher', scope_staff_id: 'staff-1', scope_section_ids: null } }, 'teacher');
    const sheets = buildTeacherSheets(p);
    expect(sheets).toHaveLength(1);
    expect(sheets[0]!.rows.flatMap((r) => r.cells).every((c) => c === null)).toBe(true);
  });
});

describe('buildMasterPages', () => {
  it('AC3: one page per school weekday, one row per section, one column per period', () => {
    const pages = buildMasterPages(payload({}, 'master'));
    expect(pages).toHaveLength(6);
    expect(pages[0]!.rows).toHaveLength(2);
    expect(pages[0]!.periodNumbers).toEqual([1, 2]);
    expect(pages[0]!.rows[0]!.cells[0]?.subject_code).toBe('PHY');
    expect(pages[1]!.rows[0]!.cells[0]).toBeNull();
  });
});

describe('masterGridMetrics', () => {
  it('AC3: 34 sections fit on one A3 landscape page at a legible size', () => {
    const metrics = masterGridMetrics(34);
    expect(metrics.fitsOnePage).toBe(true);
    expect(metrics.fontPt).toBeGreaterThanOrEqual(5.5);
    expect(metrics.rowHeightMm * 35).toBeLessThanOrEqual(297 - 20);
  });

  it('scales the font up when there are fewer rows to fit', () => {
    expect(masterGridMetrics(8).fontPt).toBeGreaterThan(masterGridMetrics(34).fontPt);
  });

  it('reports honestly when even the minimum legible size cannot fit', () => {
    expect(masterGridMetrics(200).fitsOnePage).toBe(false);
  });
});

describe('sheetGridMetrics', () => {
  it('AC2: an 8-period sheet fits one A4 page', () => {
    expect(sheetGridMetrics(8).fitsOnePage).toBe(true);
  });

  it('shrinks as the bell template grows', () => {
    expect(sheetGridMetrics(12).fontPt).toBeLessThanOrEqual(sheetGridMetrics(6).fontPt);
  });
});

describe('collectUrduStrings', () => {
  it('collects the subject and class-level names a section sheet prints', () => {
    expect(collectUrduStrings(payload()).sort()).toEqual(['جماعت', 'سینا اسکول', 'فزکس'].sort());
  });

  it('skips subject names on the master grid, which prints Latin subject codes', () => {
    expect(collectUrduStrings(payload({}, 'master'))).toEqual(['سینا اسکول']);
  });
});

describe('sectionLabel', () => {
  it('reads the way a noticeboard sheet is titled', () => {
    expect(sectionLabel(section('x', 'A', 9))).toBe('Class 9 A');
  });
});

describe('buildExportHtml', () => {
  it('sets A4 portrait for section and teacher sheets, A3 landscape for the master grid', () => {
    expect(buildExportHtml(payload(), null, null)).toMatchObject({ pageFormat: 'A4', landscape: false });
    expect(buildExportHtml(payload({}, 'master'), null, null)).toMatchObject({ pageFormat: 'A3', landscape: true });
    expect(buildExportHtml(payload({}, 'master'), null, null).html).toContain('@page { size: A3 landscape');
  });

  it('AC2: every page carries school name, campus, session and version number', () => {
    const { html } = buildExportHtml(payload(), null, null);
    expect(html).toContain('Seena School');
    expect(html).toContain('Gulberg');
    expect(html).toContain('Session 2026-27');
    expect(html).toContain('Timetable version 3');
    expect(html.match(/class="sheet-header"/g)).toHaveLength(2);
  });

  it('AC4: the Urdu subject name leads on an Urdu-medium section', () => {
    const { html } = buildExportHtml(payload({ sections: [section('sec-a', 'A', 1, 'URDU')] }), null, null);
    expect(html).toContain('<div class="subject"><span class="ur">فزکس</span></div>');
  });

  it('AC4: the Urdu subject name still prints on an English-medium section, as the second line', () => {
    const { html } = buildExportHtml(payload(), null, null);
    expect(html).toContain('<div class="subject"><span class="en">Physics</span></div>');
    expect(html).toContain('<span class="ur">فزکس</span>');
  });

  it('escapes markup coming out of tenant data', () => {
    const { html } = buildExportHtml(payload({ tenant: { name: '<script>x</script>', name_ur: null } }), null, null);
    expect(html).not.toContain('<script>x</script>');
    expect(html).toContain('&lt;script&gt;');
  });

  it('renders a readable page rather than nothing when the version has no sections', () => {
    const { html } = buildExportHtml(payload({ sections: [], slots: [] }), null, null);
    expect(html).toContain('no scheduled periods in scope');
  });
});

describe('pdf byte helpers', () => {
  const bytes = Buffer.from('%PDF-1.4\n1 0 obj<</Type /Pages /Count 2>>\n2 0 obj<</Type /Page>>\n3 0 obj<</Type /Page>>\n/BaseFont /BAAAAA+NotoNastaliqUrdu\n');

  it('recognises PDF bytes', () => {
    expect(isPdf(bytes)).toBe(true);
    expect(isPdf(Buffer.from('<html>'))).toBe(false);
  });

  it('counts page objects without counting the page tree', () => {
    expect(pdfPageCount(bytes)).toBe(2);
  });

  it('reports embedded fonts with the subset prefix stripped', () => {
    expect(embeddedFontNames(bytes)).toEqual(['NotoNastaliqUrdu']);
  });
});
