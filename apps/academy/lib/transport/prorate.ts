// Mirror of app.fn_prorate_transport (FR-P04), used for the fee preview on the
// allocation screen. The database is the source of truth; this exists so a clerk
// sees the figure before saving, and so the arithmetic is unit tested.

export type ProratePolicy = 'prorata' | 'full_month';

const DAY = 86_400_000;
const utc = (iso: string) => Date.parse(`${iso}T00:00:00Z`);

function monthBounds(month: string): { start: number; end: number; days: number } {
  const [y, m] = month.split('-').map(Number) as [number, number];
  const start = Date.UTC(y, m - 1, 1);
  const end = Date.UTC(y, m, 0);
  return { start, end, days: (end - start) / DAY + 1 };
}

/**
 * What an allocation costs for one month, in paisa. `endsOn` is the last day of
 * service (null = still riding). Pro-rata is days of service over days in the
 * month, rounded to a whole rupee; full-month charges the slab once the bus is
 * used on any day of the month.
 */
export function transportFeePaisa(monthlyPaisa: number, startsOn: string, endsOn: string | null, month: string, policy: ProratePolicy): number {
  const { start, end, days } = monthBounds(month);
  const from = Math.max(utc(startsOn), start);
  const to = Math.min(endsOn ? utc(endsOn) : end, end);
  if (to < from) return 0;
  if (policy === 'full_month') return monthlyPaisa;
  const served = (to - from) / DAY + 1;
  return Math.round((monthlyPaisa * served) / days / 100) * 100;
}

/** A student's lines for a month never total more than the dearest slab; later lines are trimmed. */
export function capMonthLines(lines: number[], dearestSlabPaisa: number): number[] {
  let used = 0;
  return lines.map((l) => {
    const allowed = Math.max(0, dearestSlabPaisa - used);
    const v = Math.min(l, allowed);
    used += v;
    return v;
  });
}
