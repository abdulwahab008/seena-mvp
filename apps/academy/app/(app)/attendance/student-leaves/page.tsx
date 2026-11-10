import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { formatDatePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { DecideButtons } from '@/components/decide-buttons';
import { decideStudentLeave } from './actions';

export const dynamic = 'force-dynamic';

const one = <T,>(v: T | T[] | null | undefined) => (Array.isArray(v) ? v[0] : v) ?? null;
const STATUS_TONE = { pending: 'warning', approved: 'success', rejected: 'destructive', cancelled: 'outline' } as const;

export default async function StudentLeavesPage({ searchParams }: { searchParams: Promise<{ status?: string }> }) {
  const { status: raw } = await searchParams;
  const status = raw && raw in STATUS_TONE ? (raw as keyof typeof STATUS_TONE) : 'pending';
  const supabase = await supabaseServer();
  const { data: leaves, error } = await supabase
    .from('student_leave_application')
    .select('id, from_date, to_date, reason_category, remarks, status, applied_via, decision_note, created_at, enrolment:enrolment_id(student:student_id(id, name_en, gr_number), class_level:class_level_id(name_en), section:section_id(name))')
    .eq('status', status)
    .order('from_date', { ascending: status === 'pending' })
    .limit(200);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Student leave requests</h1>
        <p className="text-sm text-muted-foreground">Leave asked for by parents from the portal or by the office. Approve or reject each one.</p>
      </div>
      <nav className="flex flex-wrap gap-2" aria-label="Status">
        {Object.keys(STATUS_TONE).map((s) => (
          <Link
            key={s}
            href={`/attendance/student-leaves?status=${s}`}
            aria-current={s === status ? 'page' : undefined}
            className={`rounded-full border px-3 py-1 text-sm capitalize ${s === status ? 'border-primary bg-primary text-primary-foreground' : 'hover:bg-muted'}`}
          >
            {s}
          </Link>
        ))}
      </nav>
      {error ? (
        <p className="text-sm text-destructive">Could not load leave requests. Try again.</p>
      ) : (leaves ?? []).length === 0 ? (
        <p className="text-sm text-muted-foreground">No {status} leave requests.</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Student</TableHead>
              <TableHead>Class</TableHead>
              <TableHead>From</TableHead>
              <TableHead>To</TableHead>
              <TableHead>Reason</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>{status === 'pending' ? 'Decide' : 'Note'}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {(leaves ?? []).map((l) => {
              const e = one(l.enrolment);
              const s = one(e?.student);
              return (
                <TableRow key={l.id} data-testid="leave-row">
                  <TableCell>
                    {s && (
                      <Link href={`/students/${s.id}`} className="font-medium hover:underline">
                        {s.name_en} <span className="text-muted-foreground">({s.gr_number})</span>
                      </Link>
                    )}
                  </TableCell>
                  <TableCell>{`${one(e?.class_level)?.name_en ?? ''} ${one(e?.section)?.name ?? ''}`.trim()}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(l.from_date)}</TableCell>
                  <TableCell className="whitespace-nowrap">{formatDatePk(l.to_date)}</TableCell>
                  <TableCell className="max-w-xs">
                    <span className="capitalize">{l.reason_category}</span>
                    {l.remarks && <span className="block text-xs text-muted-foreground">{l.remarks}</span>}
                  </TableCell>
                  <TableCell>
                    <Badge variant={STATUS_TONE[l.status]}>{l.status}</Badge>
                  </TableCell>
                  <TableCell>{l.status === 'pending' ? <DecideButtons id={l.id} action={decideStudentLeave} approvedText="Leave approved." rejectedText="Leave rejected." /> : (l.decision_note ?? '')}</TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      )}
    </div>
  );
}
