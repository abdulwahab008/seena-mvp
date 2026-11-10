'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { saveRollCall } from './actions';
import { ROLL_STATUSES } from './statuses';

const LABEL = { present: 'Present', absent: 'Absent', on_leave: 'Leave' } as const;
const schema = z.object({ marks: z.record(z.string(), z.enum(ROLL_STATUSES)) });

export type Resident = { studentId: string; name: string; gr: string; bed: string; block: string; status: (typeof ROLL_STATUSES)[number] | null };

export function RollCallForm({ campusId, date, session, residents }: { campusId: string; date: string; session: 'morning' | 'night'; residents: Resident[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  // Keys are prefixed: a UUID that starts with a digit would make react-hook-form build an array.
  const { register, handleSubmit, setValue } = useForm<z.infer<typeof schema>>({
    resolver: zodResolver(schema),
    defaultValues: { marks: Object.fromEntries(residents.map((r) => [`s${r.studentId}`, r.status ?? 'present'])) },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const rows = Object.entries(v.marks).map(([k, status]) => ({ student_id: k.slice(1), status }));
      const res = await saveRollCall({ campusId, date, session, rows });
      if (res.error) return void toast.error(res.error);
      toast.success(`Roll call saved for ${res.saved} residents.`);
      router.refresh();
    }),
  );

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="flex flex-wrap gap-2">
        <Button type="button" size="sm" variant="outline" onClick={() => residents.forEach((r) => setValue(`marks.s${r.studentId}`, 'present'))}>
          Mark all present
        </Button>
        <Button type="submit" size="sm" disabled={pending}>
          {pending ? 'Saving…' : 'Save roll call'}
        </Button>
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-10">#</TableHead>
            <TableHead>Resident</TableHead>
            <TableHead>GR no.</TableHead>
            <TableHead>Block</TableHead>
            <TableHead>Bed</TableHead>
            <TableHead>Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {residents.map((r, i) => (
            <TableRow key={r.studentId} data-testid="roll-call-row">
              <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
              <TableCell className="font-medium">{r.name}</TableCell>
              <TableCell className="tabular font-mono">{r.gr}</TableCell>
              <TableCell>{r.block}</TableCell>
              <TableCell className="tabular">{r.bed}</TableCell>
              <TableCell>
                <div className="flex gap-3 text-sm" role="radiogroup" aria-label={`Status for ${r.name}`}>
                  {ROLL_STATUSES.map((st) => (
                    <label key={st} className="flex items-center gap-1">
                      <input type="radio" value={st} {...register(`marks.s${r.studentId}`)} />
                      {LABEL[st]}
                    </label>
                  ))}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </form>
  );
}
