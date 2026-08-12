import { WEEKDAY_LABELS } from '@/lib/validation';

export type ExportLayout = 'section' | 'teacher' | 'master';

/** Monday–Saturday; Sunday is the weekly off day (same as /my-timetable). */
export const SCHOOL_WEEKDAYS = [1, 2, 3, 4, 5, 6] as const;

export type PayloadSlot = {
  section_id: string;
  weekday: number;
  period_no: number;
  subject_code: string;
  subject_name_en: string;
  subject_name_ur: string;
  staff_id: string | null;
  teacher_name: string | null;
  room_code: string | null;
  elective_bucket: number | null;
};

export type PayloadSection = {
  id: string;
  name: string;
  medium: 'ENGLISH' | 'URDU';
  class_level_name_en: string;
  class_level_name_ur: string | null;
  class_level_ordinal: number;
};

export type PayloadPeriod = { period_no: number; start_time: string | null; end_time: string | null };

export type PayloadTeacher = { id: string; name: string | null };

export type ExportPayload = {
  job: { id: string; layout: ExportLayout; scope_staff_id: string | null; scope_section_ids: string[] | null };
  tenant: { name: string; name_ur: string | null };
  campus: { id: string; code: string; name: string; name_ur: string | null };
  session: { id: string; name: string };
  version: {
    id: string;
    name: string;
    version_no: number;
    status: string;
    shift: string;
    effective_from: string | null;
    effective_to: string | null;
  };
  logo_storage_path: string | null;
  periods: PayloadPeriod[];
  sections: PayloadSection[];
  slots: PayloadSlot[];
  teachers: PayloadTeacher[];
};

export type Sheet = {
  /** One sheet is one printed page — the header repeats on every one. */
  key: string;
  title: string;
  subtitle: string;
  /** Row per period, cell per weekday. */
  rows: Array<{ period: PayloadPeriod; cells: Array<PayloadSlot | null> }>;
};

export type MasterPage = {
  key: string;
  weekday: number;
  title: string;
  periodNumbers: number[];
  rows: Array<{ section: PayloadSection; label: string; cells: Array<PayloadSlot | null> }>;
};

export function weekdayLabel(weekday: number): string {
  return WEEKDAY_LABELS[weekday] ?? `Day ${weekday}`;
}

export function sectionLabel(section: PayloadSection): string {
  return `${section.class_level_name_en} ${section.name}`;
}

/**
 * The bell template is the source of truth for which periods exist and
 * when they run, but a slot can legitimately sit on a period number the
 * currently-resolved template no longer has (an older template was in
 * force when the grid was built). Printing the union means a sheet never
 * silently drops a scheduled period.
 */
export function resolvePeriods(payload: ExportPayload): PayloadPeriod[] {
  const byNo = new Map<number, PayloadPeriod>();
  for (const p of payload.periods) byNo.set(p.period_no, p);
  for (const s of payload.slots) {
    if (!byNo.has(s.period_no)) byNo.set(s.period_no, { period_no: s.period_no, start_time: null, end_time: null });
  }
  return [...byNo.values()].sort((a, b) => a.period_no - b.period_no);
}

export function formatPeriodTime(period: PayloadPeriod): string {
  if (!period.start_time || !period.end_time) return '';
  return `${period.start_time.slice(0, 5)}–${period.end_time.slice(0, 5)}`;
}

export function buildSectionSheets(payload: ExportPayload): Sheet[] {
  const periods = resolvePeriods(payload);
  return payload.sections.map((section) => ({
    key: `section-${section.id}`,
    title: sectionLabel(section),
    subtitle: section.medium === 'URDU' ? 'Urdu medium' : 'English medium',
    rows: periods.map((period) => ({
      period,
      cells: SCHOOL_WEEKDAYS.map(
        (weekday) =>
          payload.slots.find((s) => s.section_id === section.id && s.weekday === weekday && s.period_no === period.period_no) ?? null,
      ),
    })),
  }));
}

export function buildTeacherSheets(payload: ExportPayload): Sheet[] {
  const periods = resolvePeriods(payload);
  const teachers = [...payload.teachers].sort((a, b) => (a.name ?? '').localeCompare(b.name ?? ''));
  return teachers.map((teacher) => ({
    key: `teacher-${teacher.id}`,
    title: teacher.name ?? 'Unnamed staff member',
    subtitle: 'Teaching schedule',
    rows: periods.map((period) => ({
      period,
      cells: SCHOOL_WEEKDAYS.map(
        (weekday) =>
          payload.slots.find((s) => s.staff_id === teacher.id && s.weekday === weekday && s.period_no === period.period_no) ?? null,
      ),
    })),
  }));
}

export function buildMasterPages(payload: ExportPayload): MasterPage[] {
  const periodNumbers = resolvePeriods(payload).map((p) => p.period_no);
  return SCHOOL_WEEKDAYS.map((weekday) => ({
    key: `master-${weekday}`,
    weekday,
    title: weekdayLabel(weekday),
    periodNumbers,
    rows: payload.sections.map((section) => ({
      section,
      label: sectionLabel(section),
      cells: periodNumbers.map(
        (periodNo) =>
          payload.slots.find((s) => s.section_id === section.id && s.weekday === weekday && s.period_no === periodNo) ?? null,
      ),
    })),
  }));
}

export function pageCountFor(payload: ExportPayload): number {
  if (payload.job.layout === 'section') return payload.sections.length;
  if (payload.job.layout === 'teacher') return payload.teachers.length;
  return SCHOOL_WEEKDAYS.length;
}

/** A3 landscape is 420mm × 297mm; 10mm margins and ~34mm of header. */
const A3_LANDSCAPE_BODY_HEIGHT_MM = 297 - 2 * 10 - 34;
const MIN_MASTER_FONT_PT = 5.5;
const MAX_MASTER_FONT_PT = 9;
const PT_TO_MM = 25.4 / 72;

export type MasterGridMetrics = { rowHeightMm: number; fontPt: number; fitsOnePage: boolean };

/**
 * AC3: 34 section rows on one A3 landscape page, "every section row legible
 * and no truncation". Row height is derived from the space actually
 * available rather than fixed, and the font is scaled to fit two lines
 * (subject code + room) inside it, clamped so it never drops below a
 * legible floor — if even the floor does not fit, fitsOnePage is false and
 * the caller can say so rather than silently clipping rows off the page.
 */
export function masterGridMetrics(sectionCount: number): MasterGridMetrics {
  const rows = Math.max(sectionCount, 1) + 1; // + header row
  const rowHeightMm = A3_LANDSCAPE_BODY_HEIGHT_MM / rows;
  // Two 1.15-line-height lines plus 0.6mm of cell padding above and below.
  const idealPt = (rowHeightMm - 1.2) / (2 * 1.15 * PT_TO_MM);
  // Floored, never rounded: rounding 7.078pt up to 7.1pt is what turns a
  // grid that fits into one that spills a row onto a second page.
  const fontPt = Math.min(MAX_MASTER_FONT_PT, Math.max(MIN_MASTER_FONT_PT, Math.floor(idealPt * 10) / 10));
  const neededMm = fontPt * 2 * 1.15 * PT_TO_MM + 1.2;
  return { rowHeightMm, fontPt, fitsOnePage: neededMm <= rowHeightMm + 0.001 };
}

/** A4 portrait is 210mm × 297mm; 12mm margins and ~30mm of header. */
const A4_PORTRAIT_BODY_HEIGHT_MM = 297 - 2 * 12 - 30;
const MIN_SHEET_FONT_PT = 6.5;
const MAX_SHEET_FONT_PT = 10;

export type SheetGridMetrics = { rowHeightMm: number; fontPt: number; fitsOnePage: boolean };

/**
 * AC2: "each teacher occupies exactly one A4 page". A sheet cell carries
 * three lines (subject, section or teacher, room), so the font is scaled
 * to whatever height the period rows actually leave — a 12-period bell
 * template must not silently push the last row onto a second page.
 */
export function sheetGridMetrics(periodCount: number): SheetGridMetrics {
  const rows = Math.max(periodCount, 1) + 1; // + header row
  const rowHeightMm = A4_PORTRAIT_BODY_HEIGHT_MM / rows;
  const idealPt = (rowHeightMm - 1.6) / (3 * 1.15 * PT_TO_MM);
  const fontPt = Math.min(MAX_SHEET_FONT_PT, Math.max(MIN_SHEET_FONT_PT, Math.floor(idealPt * 10) / 10));
  const neededMm = fontPt * 3 * 1.15 * PT_TO_MM + 1.6;
  return { rowHeightMm, fontPt, fitsOnePage: neededMm <= rowHeightMm + 0.001 };
}

/**
 * Every Urdu-script string the chosen layout actually prints, for the AC4
 * glyph-coverage check. Layout-aware on purpose: the master grid prints
 * subject CODES (Latin, by design in this schema) rather than names, so
 * checking its subject names would be checking glyphs nobody is about to
 * render.
 */
export function collectUrduStrings(payload: ExportPayload): string[] {
  const out = new Set<string>();
  const add = (s: string | null | undefined) => {
    if (s && s.trim()) out.add(s);
  };
  add(payload.tenant.name_ur);
  add(payload.campus.name_ur);
  if (payload.job.layout !== 'master') {
    for (const section of payload.sections) add(section.class_level_name_ur);
    for (const slot of payload.slots) add(slot.subject_name_ur);
  }
  return [...out];
}
