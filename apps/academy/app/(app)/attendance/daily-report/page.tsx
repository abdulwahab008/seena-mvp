import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { allRows } from '@/lib/supabase/all-rows';
import { formatDatePk, todayPk } from '@/lib/dates';
import { cn } from '@/lib/utils';
import { PrintButton } from '@/components/print-button';
import { Stat } from '@/components/ui/page-header';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
// Students' "excused" and staff "on_leave" are both shown as leave.
const GROUP: Record<string, 'present' | 'absent' | 'late' | 'leave' | 'half_day'> = {
  present: 'present', absent: 'absent', late: 'late', half_day: 'half_day', excused: 'leave', on_leave: 'leave',
};
const LABEL = { present: 'Present', absent: 'Absent', late: 'Late', half_day: 'Half day', leave: 'Leave' } as const;
const TONE = { present: 'success', absent: 'destructive', late: 'warning', half_day: 'outline', leave: 'outline' } as const;
type Group = keyof typeof LABEL;
type Row = { id: string; name: string; code: string; group: string; status: Group; time: string | null };

export default async function DailyAttendanceReportPage({ searchParams }: { searchParams: Promise<{ date?: string; who?: string; status?: string }> }) {
  const f = await searchParams;
  const today = todayPk();
  const date = f.date && /^\d{4}-\d{2}-\d{2}$/.test(f.date) && f.date <= today ? f.date : today;
  const who = f.who === 'staff' ? 'staff' : 'students';
  const status = f.status && f.status in LABEL ? (f.status as Group) : null;
  const supabase = await supabaseServer();

  let rows: Row[] = [];
  if (who === 'students') {
    const { data } = await allRows((from, to) =>
      supabase
        .from('attendance_day')
        .select('id, status, arrival_time, enrolment:enrolment_id(student:student_id(name_en, gr_number)), section:section_id(name, class_level:class_level_id(name_en, ordinal))')
        .eq('attendance_date', date)
        .order('id')
        .range(from, to),
    );
    rows = data
      .map((a) => {
        const s = one(one(a.enrolment)?.student);
        const sec = one(a.section);
        return { id: a.id, name: s?.name_en ?? '', code: s?.gr_number ?? '', group: `${one(sec?.class_level)?.name_en ?? ''} ${sec?.name ?? ''}`.trim(), status: GROUP[a.status] ?? 'present', time: a.arrival_time, sort: one(sec?.class_level)?.ordinal ?? 0 };
      })
      .sort((a, b) => a.sort - b.sort || a.group.localeCompare(b.group) || a.name.localeCompare(b.name));
  } else {
    const { data } = await supabase
      .from('staff_attendance')
      .select('id, status, staff:staff_id(full_name, employee_code, designation:designation_id(name_en))')
      .eq('att_date', date);
    rows = (data ?? [])
      .map((a) => {
        const s = one(a.staff);
        return { id: a.id, name: s?.full_name ?? '', code: s?.employee_code ?? '', group: one(s?.designation)?.name_en ?? '', status: GROUP[a.status] ?? 'present', time: null };
      })
      .sort((a, b) => a.name.localeCompare(b.name));
  }
  const count = (g: Group) => rows.filter((r) => r.status === g).length;
  const shown = status ? rows.filter((r) => r.status === status) : rows;
  const href = (p: Record<string, string | null>) => {
    const q = new URLSearchParams({ date, who, ...(status ? { status } : {}) });
    for (const [k, v] of Object.entries(p)) v === null ? q.delete(k) : q.set(k, v);
    return `/attendance/daily-report?${q}`;
  };
  const pill = (active: boolean) => cn('rounded-full border px-3 py-1 text-sm', active ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Daily attendance report</h1>
          <p className="text-sm text-muted-foreground">
            Who was present, absent, late or on leave on {formatDatePk(date)}.
          </p>
        </div>
        <div className="print:hidden">
          <PrintButton />
        </div>
      </div>
      <div className="flex flex-wrap items-end gap-4 print:hidden">
        <nav className="flex gap-2" aria-label="Who">
          <Link href={href({ who: 'students' })} className={pill(who === 'students')} aria-current={who === 'students' ? 'page' : undefined}>
            Students
          </Link>
          <Link href={href({ who: 'staff' })} className={pill(who === 'staff')} aria-current={who === 'staff' ? 'page' : undefined}>
            Staff
          </Link>
        </nav>
        <form method="get" className="flex items-end gap-2 text-sm">
          <input type="hidden" name="who" value={who} />
          {status && <input type="hidden" name="status" value={status} />}
          <input type="date" name="date" defaultValue={date} max={today} aria-label="Date" className="h-9 rounded-md border bg-background px-2" />
          <Button type="submit" size="sm" variant="outline">
            Show
          </Button>
        </form>
      </div>
      <section aria-label="Summary" className="grid gap-3 sm:grid-cols-3 xl:grid-cols-6">
        <Stat label="Marked" value={rows.length} />
        {(Object.keys(LABEL) as Group[]).map((g) => (
          <Stat key={g} label={LABEL[g]} value={count(g)} tone={g === 'absent' && count(g) > 0 ? 'destructive' : g === 'present' ? 'success' : g === 'late' && count(g) > 0 ? 'warning' : 'default'} />
        ))}
      </section>
      <nav className="flex flex-wrap gap-2 print:hidden" aria-label="Status">
        <Link href={href({ status: null })} className={pill(!status)}>
          Everyone
        </Link>
        {(Object.keys(LABEL) as Group[]).map((g) => (
          <Link key={g} href={href({ status: g })} className={pill(status === g)} aria-current={status === g ? 'page' : undefined}>
            {LABEL[g]} list
          </Link>
        ))}
      </nav>
      {shown.length === 0 ? (
        <p className="text-sm text-muted-foreground">{rows.length === 0 ? 'No attendance was marked on this date.' : 'Nobody in this list.'}</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-10">#</TableHead>
              <TableHead>{who === 'students' ? 'GR no.' : 'Employee no.'}</TableHead>
              <TableHead>Name</TableHead>
              <TableHead>{who === 'students' ? 'Class' : 'Designation'}</TableHead>
              <TableHead>Status</TableHead>
              {who === 'students' && <TableHead>Arrived</TableHead>}
            </TableRow>
          </TableHeader>
          <TableBody>
            {shown.map((r, i) => (
              <TableRow key={r.id} data-testid="daily-attendance-row">
                <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                <TableCell className="tabular font-mono">{r.code}</TableCell>
                <TableCell className="font-medium">{r.name}</TableCell>
                <TableCell>{r.group}</TableCell>
                <TableCell>
                  <Badge variant={TONE[r.status]}>{LABEL[r.status]}</Badge>
                </TableCell>
                {who === 'students' && <TableCell className="tabular">{r.time?.slice(0, 5) ?? ''}</TableCell>}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
