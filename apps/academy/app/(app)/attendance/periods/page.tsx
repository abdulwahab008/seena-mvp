import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { PeriodForm } from './period-form';

type SearchParams = { date?: string; slot?: string };
const STATUS = ['present', 'absent', 'late', 'half_day', 'excused'] as const;
const isStatus = (v: string | null): v is (typeof STATUS)[number] => STATUS.some((s) => s === v);

function today(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });
}

export default async function PeriodAttendancePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const date = /^\d{4}-\d{2}-\d{2}$/.test(sp.date ?? '') ? (sp.date as string) : today();
  const supabase = await supabaseServer();
  const { data: slots } = await supabase.rpc('period_attendance_slots', { p_date: date });

  let roster: { enrolmentId: string; name: string; grNumber: string; status: (typeof STATUS)[number] | null }[] = [];
  let rosterError: string | null = null;
  if (sp.slot) {
    const { data, error } = await supabase.rpc('period_attendance_roster', { p_slot_id: sp.slot, p_date: date });
    if (error) rosterError = error.message.includes('NOT_ASSIGNED_TO_THIS_PERIOD') ? 'You are not assigned to this period.' : 'This period could not be opened.';
    else roster = (data ?? []).map((r) => ({ enrolmentId: r.enrolment_id, name: r.student_name, grNumber: r.gr_number, status: isStatus(r.status) ? r.status : null }));
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Period attendance</h1>
        <p className="text-sm text-muted-foreground">
          FR-G03 — mark the students of your own period. The day is worked out from the periods overnight (none present = absent, under half = half day); a day mark made by hand is never overwritten.
        </p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Date</span>
          <input type="date" name="date" defaultValue={date} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <button type="submit" className="h-9 rounded-md border px-3">
          Show my periods
        </button>
      </form>

      <div className="space-y-1 text-sm" data-testid="period-slots">
        {(slots ?? []).length === 0 && <p className="text-muted-foreground">No periods of yours run on this date.</p>}
        {(slots ?? []).map((s) => (
          <Link key={s.slot_id} href={`/attendance/periods?date=${date}&slot=${s.slot_id}`} className="flex justify-between rounded-md border px-3 py-2 hover:bg-muted" data-testid="period-slot">
            <span>
              Period {s.period_no} · {s.subject_name} · {s.section_label}
            </span>
            <span className="text-muted-foreground">{Number(s.marked_count) > 0 ? `${s.marked_count} marked` : 'not marked'}</span>
          </Link>
        ))}
      </div>

      {sp.slot && rosterError && (
        <p role="alert" className="text-sm text-destructive" data-testid="period-not-assigned">
          {rosterError}
        </p>
      )}
      {sp.slot && !rosterError && <PeriodForm key={`${sp.slot}-${date}`} slotId={sp.slot} date={date} students={roster} />}
    </div>
  );
}
