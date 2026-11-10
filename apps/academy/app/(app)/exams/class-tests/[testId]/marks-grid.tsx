'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { saveClassTestMarks, sendClassTestResults } from '../actions';

export type MarkRow = { studentId: string; name: string; gr: string; marks: number | null; absent: boolean };

export function MarksGrid({ testId, total, rows, resultsSent }: { testId: string; total: number; rows: MarkRow[]; resultsSent: boolean }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const schema = z.object({
    rows: z.array(z.object({ marks: z.string().refine((v) => v === '' || (Number(v) >= 0 && Number(v) <= total), `0 to ${total}`), absent: z.boolean() })),
  });
  const { register, handleSubmit, watch, formState: { errors } } = useForm<z.infer<typeof schema>>({
    resolver: zodResolver(schema),
    defaultValues: { rows: rows.map((r) => ({ marks: r.marks === null ? '' : String(r.marks), absent: r.absent })) },
  });
  const values = watch('rows');

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const payload = rows
        .map((r, i) => {
          const m = v.rows[i] ?? { marks: '', absent: false };
          return { student_id: r.studentId, marks: m.absent || m.marks === '' ? null : Number(m.marks), absent: m.absent };
        })
        .filter((r) => r.absent || r.marks !== null);
      if (payload.length === 0) return void toast.error('Enter marks for at least one student.');
      const res = await saveClassTestMarks({ testId, rows: payload });
      if (res.error) return void toast.error(res.error);
      toast.success('Marks saved.');
      router.refresh();
    }),
  );
  const send = () =>
    startTransition(async () => {
      const res = await sendClassTestResults(testId);
      if (res.error) return void toast.error(res.error);
      toast.success(`Queued ${res.queued} SMS${res.skipped ? `; ${res.skipped} had no parent phone` : ''}.`);
      router.refresh();
    });

  return (
    <form onSubmit={onSubmit} className="space-y-4">
      <div className="flex flex-wrap gap-2 print:hidden">
        <Button type="submit" size="sm" disabled={pending}>
          Save marks
        </Button>
        <Button type="button" size="sm" variant="outline" disabled={pending} onClick={send}>
          {resultsSent ? 'Send results again' : 'Send results by SMS'}
        </Button>
      </div>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-10">#</TableHead>
            <TableHead>GR no.</TableHead>
            <TableHead>Student</TableHead>
            <TableHead>Marks (out of {total})</TableHead>
            <TableHead>Absent</TableHead>
            <TableHead className="text-right">%</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {rows.map((r, i) => {
            const m = values[i] ?? { marks: '', absent: false };
            const pct = !m.absent && m.marks !== '' ? Math.round((Number(m.marks) / total) * 100) : null;
            return (
              <TableRow key={r.studentId} data-testid="mark-row">
                <TableCell className="tabular text-muted-foreground">{i + 1}</TableCell>
                <TableCell className="tabular font-mono">{r.gr}</TableCell>
                <TableCell className="font-medium">{r.name}</TableCell>
                <TableCell>
                  <input
                    type="number"
                    step="0.5"
                    min={0}
                    max={total}
                    aria-label={`Marks for ${r.name}`}
                    disabled={m.absent}
                    className="h-8 w-24 rounded-md border bg-background px-2 disabled:opacity-50"
                    {...register(`rows.${i}.marks`)}
                  />
                  {errors.rows?.[i]?.marks && <span className="ml-2 text-xs text-destructive">{errors.rows[i]?.marks?.message}</span>}
                </TableCell>
                <TableCell>
                  <input type="checkbox" aria-label={`${r.name} absent`} {...register(`rows.${i}.absent`)} />
                </TableCell>
                <TableCell className="tabular text-right">{pct === null ? '' : `${pct}%`}</TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </form>
  );
}
