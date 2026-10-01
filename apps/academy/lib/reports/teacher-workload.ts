import type { Column, Sheet } from '@/lib/xlsx/writer';

/** One row of get_teacher_workload(). */
export type WorkloadRow = {
  staff_id: string;
  staff_name: string;
  employee_code: string;
  iso_week: string;
  week_start: string;
  timetabled_periods: number;
  substituted_periods: number;
  delivered_periods: number;
  not_delivered_periods: number;
  contracted_periods: number | null;
  variance: number | null;
  is_overloaded: boolean;
  all_not_delivered: boolean;
};

/** ISO 8601 week of a calendar date, as `YYYY-Www` (the form mv_teacher_weekly_load stores). */
export function isoWeekOf(isoDate: string): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  const day = (d.getUTCDay() + 6) % 7; // Monday = 0
  d.setUTCDate(d.getUTCDate() - day + 3); // the Thursday of this ISO week decides the year
  const isoYear = d.getUTCFullYear();
  const firstThursday = new Date(Date.UTC(isoYear, 0, 4));
  const week = 1 + Math.round(((d.getTime() - firstThursday.getTime()) / 86_400_000 - 3 + ((firstThursday.getUTCDay() + 6) % 7)) / 7);
  return `${isoYear}-W${String(week).padStart(2, '0')}`;
}

/** The Monday that starts an ISO week. */
export function mondayOfIsoWeek(isoWeek: string): string | null {
  const m = /^(\d{4})-W(\d{2})$/.exec(isoWeek);
  if (!m) return null;
  const year = Number(m[1]);
  const week = Number(m[2]);
  if (week < 1 || week > 53) return null;
  const jan4 = new Date(Date.UTC(year, 0, 4));
  const mondayWeek1 = new Date(jan4);
  mondayWeek1.setUTCDate(jan4.getUTCDate() - ((jan4.getUTCDay() + 6) % 7));
  mondayWeek1.setUTCDate(mondayWeek1.getUTCDate() + (week - 1) * 7);
  const result = mondayWeek1.toISOString().slice(0, 10);
  return isoWeekOf(result) === isoWeek ? result : null;
}

export function shiftIsoWeek(isoWeek: string, weeks: number): string | null {
  const monday = mondayOfIsoWeek(isoWeek);
  if (!monday) return null;
  const d = new Date(`${monday}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + weeks * 7);
  return isoWeekOf(d.toISOString().slice(0, 10));
}

export const WORKLOAD_COLUMNS: Column[] = [
  { key: 'teacher', label: 'Teacher', type: 'text' },
  { key: 'code', label: 'Employee code', type: 'text' },
  { key: 'contracted', label: 'Contracted periods', type: 'int' },
  { key: 'timetabled', label: 'Timetabled periods', type: 'int' },
  { key: 'variance', label: 'Variance', type: 'int' },
  { key: 'delivered', label: 'Delivered periods', type: 'int' },
  { key: 'notDelivered', label: 'Not delivered', type: 'int' },
  { key: 'substituted', label: 'Substitution periods covered', type: 'int' },
  { key: 'flag', label: 'Flag', type: 'text' },
];

export function workloadFlag(r: Pick<WorkloadRow, 'is_overloaded' | 'all_not_delivered'>): string {
  if (r.all_not_delivered) return 'Not delivered (absent all week)';
  if (r.is_overloaded) return 'Over-loaded';
  return '';
}

/**
 * The export sheet: a header row and exactly one row per teacher. Substitution periods have their own
 * column and are never added into the base or delivered counts.
 */
export function workloadSheet(isoWeek: string, rows: readonly WorkloadRow[]): Sheet {
  return {
    name: `Workload ${isoWeek}`.slice(0, 31),
    columns: WORKLOAD_COLUMNS,
    rows: rows.map((r) => ({
      teacher: r.staff_name,
      code: r.employee_code,
      contracted: r.contracted_periods,
      timetabled: r.timetabled_periods,
      variance: r.variance,
      delivered: r.delivered_periods,
      notDelivered: r.not_delivered_periods,
      substituted: r.substituted_periods,
      flag: workloadFlag(r),
    })),
  };
}

export function formatVariance(v: number | null): string {
  if (v === null) return '—';
  return v > 0 ? `+${v}` : String(v);
}
