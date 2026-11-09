'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { saveStaffAttendance } from './actions';
import { STAFF_STATUSES } from './statuses';

const LABEL: Record<(typeof STAFF_STATUSES)[number], string> = { present: 'Present', absent: 'Absent', late: 'Late', half_day: 'Half day', on_leave: 'Leave' };
const schema = z.object({ marks: z.record(z.string(), z.enum(STAFF_STATUSES)) });
type Values = z.infer<typeof schema>;

export type StaffMark = { id: string; name: string; code: string; designation: string | null; status: (typeof STAFF_STATUSES)[number] | null; source: string | null };

export function StaffRegister({ campusId, date, staff }: { campusId: string; date: string; staff: StaffMark[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, setValue } = useForm<Values>({
    resolver: zodResolver(schema),
    // Keys are prefixed: a UUID that starts with a digit would make react-hook-form build an array.
    defaultValues: { marks: Object.fromEntries(staff.map((s) => [`s${s.id}`, s.status ?? 'present'])) },
  });

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const rows = Object.entries(v.marks).map(([key, status]) => ({ staff_id: key.slice(1), status }));
      const res = await saveStaffAttendance({ campusId, date, rows });
      if (res.error) return void toast.error(res.error);
      toast.success(res.locked ? `Saved ${res.written}. ${res.locked} on approved leave were left as leave.` : `Saved attendance for ${res.written} staff.`);
      router.refresh();
    }),
  );

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="flex flex-wrap gap-2">
        <Button type="button" size="sm" variant="outline" onClick={() => staff.forEach((s) => setValue(`marks.s${s.id}`, 'present'))}>
          Mark all present
        </Button>
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? 'Saving…' : 'Save attendance'}
        </Button>
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-10">#</TableHead>
            <TableHead>Name</TableHead>
            <TableHead>Employee no.</TableHead>
            <TableHead>Designation</TableHead>
            <TableHead>Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {staff.map((s, i) => (
            <TableRow key={s.id} data-testid="staff-attendance-row">
              <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
              <TableCell className="font-medium">{s.name}</TableCell>
              <TableCell className="tabular font-mono">{s.code}</TableCell>
              <TableCell>{s.designation ?? ''}</TableCell>
              <TableCell>
                <div className="flex flex-wrap gap-3 text-sm" role="radiogroup" aria-label={`Status for ${s.name}`}>
                  {STAFF_STATUSES.map((st) => (
                    <label key={st} className="flex items-center gap-1">
                      <input type="radio" value={st} {...register(`marks.s${s.id}`)} />
                      {LABEL[st]}
                    </label>
                  ))}
                  {s.source && s.source !== 'manual' && <span className="text-xs text-muted-foreground">from {s.source}</span>}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </form>
  );
}
