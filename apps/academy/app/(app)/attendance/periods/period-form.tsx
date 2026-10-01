'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { periodAttendanceSchema, type PeriodAttendanceInput } from '@/lib/validation';
import { savePeriodAttendance } from './actions';
import { Button } from '@/components/ui/button';

const STATUSES = ['present', 'absent', 'late', 'half_day', 'excused'] as const;
type Student = { enrolmentId: string; name: string; grNumber: string; status: (typeof STATUSES)[number] | null };

export function PeriodForm({ slotId, date, students }: { slotId: string; date: string; students: Student[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<PeriodAttendanceInput>({
    resolver: zodResolver(periodAttendanceSchema),
    defaultValues: { slotId, date, marks: students.map((s) => ({ enrolmentId: s.enrolmentId, status: s.status ?? 'present' })) },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await savePeriodAttendance(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Period attendance saved.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate>
      <div className="divide-y rounded-md border" data-testid="period-roster">
        {students.map((s, i) => (
          <label key={s.enrolmentId} className="flex items-center justify-between gap-3 px-3 py-2 text-sm" data-testid="period-student">
            <span>
              {s.name} <span className="text-muted-foreground">GR {s.grNumber}</span>
            </span>
            <select className="h-9 rounded-md border bg-background px-2 text-sm capitalize" aria-label={`Status for ${s.name}`} {...form.register(`marks.${i}.status`)}>
              {STATUSES.map((st) => (
                <option key={st} value={st}>
                  {st.replace('_', ' ')}
                </option>
              ))}
            </select>
          </label>
        ))}
      </div>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      <Button type="submit" disabled={pending || students.length === 0} data-testid="period-save">
        Save period attendance
      </Button>
    </form>
  );
}
