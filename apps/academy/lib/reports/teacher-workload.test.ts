import { describe, expect, it } from 'vitest';
import { buildWorkbook } from '@/lib/xlsx/writer';
import { formatVariance, isoWeekOf, mondayOfIsoWeek, shiftIsoWeek, workloadFlag, workloadSheet, type WorkloadRow } from './teacher-workload';

const row = (over: Partial<WorkloadRow>): WorkloadRow => ({
  staff_id: 'id',
  staff_name: 'Teacher',
  employee_code: 'E-1',
  iso_week: '2026-W40',
  week_start: '2026-09-28',
  timetabled_periods: 30,
  substituted_periods: 0,
  delivered_periods: 30,
  not_delivered_periods: 0,
  contracted_periods: 30,
  variance: 0,
  is_overloaded: false,
  all_not_delivered: false,
  ...over,
});

describe('ISO week helpers (FR-D20)', () => {
  it('names the ISO week of a date, including year boundaries', () => {
    expect(isoWeekOf('2026-09-28')).toBe('2026-W40');
    expect(isoWeekOf('2026-10-04')).toBe('2026-W40');
    expect(isoWeekOf('2026-01-01')).toBe('2026-W01');
    expect(isoWeekOf('2021-01-03')).toBe('2020-W53');
    expect(isoWeekOf('2024-12-30')).toBe('2025-W01');
  });

  it('finds the Monday of an ISO week and refuses impossible weeks', () => {
    expect(mondayOfIsoWeek('2026-W40')).toBe('2026-09-28');
    expect(mondayOfIsoWeek('2020-W53')).toBe('2020-12-28');
    expect(mondayOfIsoWeek('2026-W53')).toBe('2026-12-28'); // 2026 starts on a Thursday, so it has 53 ISO weeks
    expect(mondayOfIsoWeek('2025-W53')).toBeNull(); // 2025 has only 52
    expect(mondayOfIsoWeek('2026-W00')).toBeNull();
    expect(mondayOfIsoWeek('nope')).toBeNull();
  });

  it('steps forward and back across a year end', () => {
    expect(shiftIsoWeek('2026-W40', 1)).toBe('2026-W41');
    expect(shiftIsoWeek('2025-W01', -1)).toBe('2024-W52');
    expect(shiftIsoWeek('2020-W53', 1)).toBe('2021-W01');
  });
});

describe('workload export (FR-D20)', () => {
  it('flags the over-loaded and the wholly-absent teacher and shows variance with its sign', () => {
    expect(workloadFlag(row({ is_overloaded: true, variance: 4 }))).toBe('Over-loaded');
    expect(workloadFlag(row({ all_not_delivered: true }))).toContain('Not delivered');
    expect(workloadFlag(row({}))).toBe('');
    expect(formatVariance(4)).toBe('+4');
    expect(formatVariance(-2)).toBe('-2');
    expect(formatVariance(0)).toBe('0');
    expect(formatVariance(null)).toBe('—');
  });

  it('keeps substitution periods in their own column and out of the base counts', () => {
    const sheet = workloadSheet('2026-W40', [row({ timetabled_periods: 34, substituted_periods: 3, delivered_periods: 34, variance: 4, is_overloaded: true })]);
    expect(sheet.rows[0]).toMatchObject({ timetabled: 34, substituted: 3, delivered: 34, variance: 4, flag: 'Over-loaded' });
  });

  it('a 40-teacher campus exports exactly one row per teacher plus a header row', () => {
    const rows = Array.from({ length: 40 }, (_, i) => row({ staff_id: `s${i}`, staff_name: `Teacher ${i}`, employee_code: `E-${i}` }));
    const sheet = workloadSheet('2026-W40', rows);
    expect(sheet.rows).toHaveLength(40);
    const bytes = buildWorkbook([sheet]);
    const text = Buffer.from(bytes).toString('utf8');
    expect(text.match(/<row r="/g)).toHaveLength(41); // header + 40
    expect(text).toContain('Substitution periods covered');
  });
});
