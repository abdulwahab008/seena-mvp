import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { WEEKDAY_LABELS } from '@/lib/validation';

const SCHOOL_WEEKDAYS = [1, 2, 3, 4, 5, 6]; // Monday–Saturday; Sunday is the weekly off day.

function mondayOf(dateStr: string): string {
  const d = new Date(`${dateStr}T00:00:00Z`);
  const day = d.getUTCDay();
  const diff = day === 0 ? -6 : 1 - day;
  d.setUTCDate(d.getUTCDate() + diff);
  return d.toISOString().slice(0, 10);
}

function addDays(dateStr: string, days: number): string {
  const d = new Date(`${dateStr}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

type Row = {
  weekday: number;
  occurs_on: string;
  period_no: number;
  start_time: string | null;
  end_time: string | null;
  campus_code: string;
  section_name: string;
  class_level_name: string;
  subject_code: string;
  subject_name_en: string;
  room_code: string | null;
  is_substitution: boolean;
  absent_teacher_name: string | null;
};

export default async function MyTimetablePage({ searchParams }: { searchParams: Promise<{ week?: string }> }) {
  const { week: weekParam } = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const today = new Date().toISOString().slice(0, 10);
  const monday = mondayOf(weekParam ?? today);
  const prevWeek = addDays(monday, -7);
  const nextWeek = addDays(monday, 7);

  const { data, error } = await supabase.rpc('teacher_timetable', { p_staff_id: user!.id, p_week_start: monday });
  const rows = (error ? [] : (data ?? [])) as Row[];

  const regular = rows.filter((r) => !r.is_substitution);
  const substitutions = rows.filter((r) => r.is_substitution);
  const periods = Array.from(new Set(rows.map((r) => r.period_no))).sort((a, b) => a - b);
  const cellAt = (weekday: number, periodNo: number) => regular.find((r) => r.weekday === weekday && r.period_no === periodNo);
  const fmtTime = (t: string | null) => (t ? t.slice(0, 5) : '');

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">My Timetable</h1>
        <p className="text-sm text-muted-foreground">FR-F12 — your own published schedule for the week, across every section and campus you teach.</p>
      </div>

      <div className="flex items-center gap-3">
        <Link href={`/my-timetable?week=${prevWeek}`} data-testid="my-timetable-prev-week" className="text-sm text-muted-foreground hover:text-foreground">
          ← Previous week
        </Link>
        <span className="text-sm font-medium" data-testid="my-timetable-week-label">
          Week of {monday}
        </span>
        <Link href={`/my-timetable?week=${nextWeek}`} data-testid="my-timetable-next-week" className="text-sm text-muted-foreground hover:text-foreground">
          Next week →
        </Link>
      </div>

      {error && <p className="text-sm text-destructive">{error.message.includes('FORBIDDEN') ? 'You do not have permission to view this timetable.' : 'Could not load your timetable.'}</p>}

      {substitutions.length > 0 && (
        <div className="space-y-2" data-testid="my-timetable-substitutions">
          <h2 className="text-sm font-semibold text-amber-900">Covering this week</h2>
          {substitutions.map((s) => (
            <div key={`${s.occurs_on}-${s.period_no}`} className="rounded-lg border border-amber-400 bg-amber-50 p-3 text-sm" data-testid={`substitution-${s.occurs_on}-${s.period_no}`}>
              {s.occurs_on} · Period {s.period_no} · {s.subject_name_en} · {s.class_level_name} {s.section_name} ({s.campus_code}) — covering for {s.absent_teacher_name}
            </div>
          ))}
        </div>
      )}

      {regular.length === 0 && substitutions.length === 0 && !error ? (
        <p className="text-sm text-muted-foreground" data-testid="my-timetable-empty">
          No published periods for this week.
        </p>
      ) : (
        <div className="overflow-x-auto rounded-lg border">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b bg-muted/50">
                <th className="p-2 text-left font-medium">Period</th>
                {SCHOOL_WEEKDAYS.map((w) => (
                  <th key={w} className="p-2 text-left font-medium">
                    {WEEKDAY_LABELS[w]}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {periods.map((periodNo) => (
                <tr key={periodNo} className="border-b last:border-0">
                  <td className="p-2 font-medium text-muted-foreground">{periodNo}</td>
                  {SCHOOL_WEEKDAYS.map((w) => {
                    const cell = cellAt(w, periodNo);
                    return (
                      <td key={w} data-testid={`my-timetable-cell-${w}-${periodNo}`} className="p-2 align-top">
                        {cell ? (
                          <div className="space-y-0.5">
                            {cell.start_time || cell.end_time ? (
                              <p className="text-xs text-muted-foreground">
                                {fmtTime(cell.start_time)}–{fmtTime(cell.end_time)}
                              </p>
                            ) : (
                              // FR-F03: the day resolved to a shorter bell
                              // template (Ramadan) that has no period this
                              // high. The slot is still published — it just
                              // isn't held today.
                              <p className="text-xs font-medium text-amber-700" data-testid={`my-timetable-not-held-${w}-${periodNo}`}>
                                Not held today
                              </p>
                            )}
                            <p className="font-medium">{cell.subject_name_en}</p>
                            <p className="text-xs text-muted-foreground">
                              {cell.class_level_name} {cell.section_name} · {cell.campus_code}
                            </p>
                            {cell.room_code && <p className="text-xs text-muted-foreground">{cell.room_code}</p>}
                          </div>
                        ) : (
                          <span className="text-xs text-muted-foreground">Free</span>
                        )}
                      </td>
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
