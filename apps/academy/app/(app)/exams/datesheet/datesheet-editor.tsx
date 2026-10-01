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
  examSettingsSchema,
  type CreateDatesheetInput,
  type DatesheetSlotInput,
  type ExamHallInput,
  type ExamSettingsInput,
} from '@/lib/validation';
import { createDatesheet, deleteSlot, publishDatesheet, reopenDatesheet, saveExamSettings, saveHall, saveSlot, type SlotWarning } from './actions';
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

/** FR-I04: publish the draft as the next version, or reopen the published one for revision. */
export function PublishPanel({ datesheetId, status, canPublish, nextVersion }: { datesheetId: string; status: string; canPublish: boolean; nextVersion: number }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [note, setNote] = useState('');
  if (status === 'published') {
    return (
      <div className="flex flex-wrap items-center gap-3">
        <Button
          variant="outline"
          disabled={pending}
          data-testid="reopen-datesheet"
          onClick={() =>
            startTransition(async () => {
              const r = await reopenDatesheet(datesheetId);
              setError(r.error);
              if (!r.error) router.refresh();
            })
          }
        >
          Reopen for revision
        </Button>
        {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      </div>
    );
  }
  return (
    <div className="flex flex-wrap items-end gap-3">
      <div className="space-y-1">
        <Label htmlFor="publishNote">{nextVersion > 1 ? 'What changed (shown to parents)' : 'Note (optional)'}</Label>
        <Input id="publishNote" className="w-80" value={note} maxLength={500} onChange={(e) => setNote(e.target.value)} />
      </div>
      <Button
        disabled={pending || !canPublish}
        data-testid="publish-datesheet"
        onClick={() =>
          startTransition(async () => {
            const r = await publishDatesheet(datesheetId, note);
            setError(r.error);
            if (!r.error) {
              toast.success(`Published as version ${r.version ?? nextVersion}.`);
              setNote('');
              router.refresh();
            }
          })
        }
      >
        Publish version {nextVersion}
      </Button>
      {error && <p role="alert" className="text-sm text-destructive" data-testid="publish-error">{error}</p>}
    </div>
  );
}

export type ExamSettingsValues = {
  jummahCutoff: string;
  invigilationMaxDuties: number;
  paperReleaseOffsetMinutes: number;
  maxModerationDelta: number;
  maxModerationPct: number | null;
};

/**
 * The exam office's campus settings, in one place: the Friday Jummah cut-off the
 * datesheet warns against (FR-I03), the invigilation duty cap (FR-I10), how long
 * before the exam a published paper unseals (FR-I08) and the moderation caps
 * (FR-I15). The question cooldown has its own card on the papers page.
 */
export function ExamSettingsForm({ campusId, values }: { campusId: string; values: ExamSettingsValues }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<ExamSettingsInput>({
    resolver: zodResolver(examSettingsSchema),
    defaultValues: {
      campusId,
      jummahCutoff: values.jummahCutoff,
      invigilationMaxDuties: values.invigilationMaxDuties,
      paperReleaseOffsetMinutes: values.paperReleaseOffsetMinutes,
      maxModerationDelta: values.maxModerationDelta,
      maxModerationPct: values.maxModerationPct,
    },
  });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveExamSettings(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Exam settings saved.');
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="setJummah">Friday Jummah cut-off</Label>
        <Input id="setJummah" type="time" {...form.register('jummahCutoff')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="setMaxDuties">Max invigilation duties per term</Label>
        <Input id="setMaxDuties" type="number" {...form.register('invigilationMaxDuties', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="setRelease">Paper release (minutes before exam)</Label>
        <Input id="setRelease" type="number" {...form.register('paperReleaseOffsetMinutes', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="setModDelta">Max moderation (marks)</Label>
        <Input id="setModDelta" type="number" step="0.5" {...form.register('maxModerationDelta', { valueAsNumber: true })} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="setModPct">Max moderation (% of max, optional)</Label>
        <Input id="setModPct" type="number" step="0.5" {...form.register('maxModerationPct', { setValueAs: (v) => (v === '' || v === null || Number.isNaN(Number(v)) ? null : Number(v)) })} />
      </div>
      <div className="sm:col-span-5">
        <Button type="submit" variant="outline" disabled={pending} data-testid="save-exam-settings">
          Save settings
        </Button>
      </div>
      {(error || firstError) && <p role="alert" className="text-sm text-destructive sm:col-span-5">{error ?? firstError}</p>}
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
