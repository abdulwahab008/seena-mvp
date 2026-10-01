'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import {
  createDatesheetSchema,
  datesheetSlotSchema,
  examHallSchema,
  type CreateDatesheetInput,
  type DatesheetSlotInput,
  type ExamHallInput,
} from '@/lib/validation';
import { createDatesheet, deleteSlot, saveHall, saveSlot, type SlotWarning } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type PaperOption = { id: string; label: string };
export type HallOption = { id: string; label: string };

export function WarningList({ warnings }: { warnings: SlotWarning[] }) {
  if (warnings.length === 0) return null;
  return (
    <ul className="space-y-1" data-testid="slot-warnings">
      {warnings.map((w, i) => (
        <li key={`${w.code}-${i}`} className={w.severity === 'warning' ? 'text-xs text-amber-700 dark:text-amber-400' : 'text-xs text-muted-foreground'} data-warning-code={w.code}>
          {w.severity === 'warning' ? 'Warning: ' : 'Note: '}
          {w.message}
        </li>
      ))}
    </ul>
  );
}

export function CreateDatesheetForm({ campusId, examTermId, defaultTitle }: { campusId: string; examTermId: string; defaultTitle: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<CreateDatesheetInput>({ resolver: zodResolver(createDatesheetSchema), defaultValues: { campusId, examTermId, title: defaultTitle } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await createDatesheet(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Datesheet created.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-3" noValidate>
      <div className="space-y-1">
        <Label htmlFor="dsTitle">Datesheet title</Label>
        <Input id="dsTitle" className="w-72" {...form.register('title')} />
        {form.formState.errors.title && <p className="text-xs text-destructive">{form.formState.errors.title.message}</p>}
      </div>
      <Button type="submit" disabled={pending} data-testid="create-datesheet">
        Create datesheet
      </Button>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
    </form>
  );
}

export function HallForm({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<ExamHallInput>({ resolver: zodResolver(examHallSchema), defaultValues: { campusId, code: '', name: '', rowsCount: 10, seatsPerRow: 12 } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveHall(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Hall saved.');
        form.reset({ campusId, code: '', name: '', rowsCount: v.rowsCount, seatsPerRow: v.seatsPerRow });
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="hallCode">Hall code</Label>
        <Input id="hallCode" {...form.register('code')} />
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="hallName">Hall name</Label>
        <Input id="hallName" {...form.register('name')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="hallRows">Rows</Label>
        <Input id="hallRows" type="number" {...form.register('rowsCount', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="hallSeats">Seats per row</Label>
        <Input id="hallSeats" type="number" {...form.register('seatsPerRow', { valueAsNumber: true })} />
      </div>
      {(error || Object.values(form.formState.errors)[0]) && (
        <p role="alert" className="text-sm text-destructive sm:col-span-5">
          {error ?? Object.values(form.formState.errors)[0]?.message}
        </p>
      )}
      <div className="sm:col-span-5">
        <Button type="submit" variant="outline" disabled={pending} data-testid="save-hall">
          Save hall
        </Button>
      </div>
    </form>
  );
}

export function SlotForm({ datesheetId, papers, halls }: { datesheetId: string; papers: PaperOption[]; halls: HallOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [warnings, setWarnings] = useState<SlotWarning[]>([]);
  const form = useForm<DatesheetSlotInput>({
    resolver: zodResolver(datesheetSlotSchema),
    defaultValues: { datesheetId, examSubjectId: papers[0]?.id ?? '', examDate: '', startTime: '09:00', endTime: '11:00', hallId: '', invigilators: 2 },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveSlot(v);
      setError(r.error);
      setWarnings(r.warnings ?? []);
      if (!r.error) {
        toast.success('Paper scheduled.');
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-6" noValidate>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="slotPaper">Paper</Label>
        <select id="slotPaper" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('examSubjectId')}>
          {papers.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="slotDate">Date</Label>
        <Input id="slotDate" type="date" {...form.register('examDate')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="slotStart">Start</Label>
        <Input id="slotStart" type="time" {...form.register('startTime')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="slotEnd">End</Label>
        <Input id="slotEnd" type="time" {...form.register('endTime')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="slotInvig">Invigilators</Label>
        <Input id="slotInvig" type="number" {...form.register('invigilators', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="slotHall">Hall</Label>
        <select id="slotHall" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('hallId')}>
          <option value="">No hall yet</option>
          {halls.map((h) => (
            <option key={h.id} value={h.id}>
              {h.label}
            </option>
          ))}
        </select>
      </div>
      <div className="flex items-end sm:col-span-4">
        <Button type="submit" disabled={pending || papers.length === 0} data-testid="save-slot">
          Save paper slot
        </Button>
      </div>
      {(error || firstError) && (
        <p role="alert" className="text-sm text-destructive sm:col-span-6" data-testid="slot-error">
          {error ?? firstError}
        </p>
      )}
      <div className="sm:col-span-6">
        <WarningList warnings={warnings} />
      </div>
    </form>
  );
}

export function RemoveSlotButton({ slotId }: { slotId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="flex items-center gap-2">
      <Button
        size="sm"
        variant="ghost"
        disabled={pending}
        onClick={() =>
          startTransition(async () => {
            const r = await deleteSlot(slotId);
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Remove
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
