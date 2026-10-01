'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { ptmEventSchema, type PtmEventInput } from '@/lib/validation';
import { createEvent, generateSlots } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function EventForm({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<PtmEventInput>({ resolver: zodResolver(ptmEventSchema), defaultValues: { title: '', eventDate: '', startTime: '09:00', cutoffHours: 24, opensAt: '', slotMinutes: 10 } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await createEvent(campusId, v);
      setError(r.error);
      if (!r.error) {
        toast.success('PTM created.');
        form.reset();
        router.refresh();
      }
    }),
  );
  const err = form.formState.errors;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
      <div className="space-y-1 sm:col-span-3">
        <Label htmlFor="ptmTitle">Title</Label>
        <Input id="ptmTitle" {...form.register('title')} />
        {err.title && <p className="text-xs text-destructive">{err.title.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptmDate">Meeting date</Label>
        <Input id="ptmDate" type="date" {...form.register('eventDate')} />
        {err.eventDate && <p className="text-xs text-destructive">{err.eventDate.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptmStart">First meeting at</Label>
        <Input id="ptmStart" type="time" {...form.register('startTime')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptmSlotMin">Slot length (minutes)</Label>
        <Input id="ptmSlotMin" type="number" {...form.register('slotMinutes', { valueAsNumber: true })} />
        {err.slotMinutes && <p className="text-xs text-destructive">{err.slotMinutes.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ptmCutoff">Booking closes (hours before)</Label>
        <Input id="ptmCutoff" type="number" {...form.register('cutoffHours', { valueAsNumber: true })} />
        {err.cutoffHours && <p className="text-xs text-destructive">{err.cutoffHours.message}</p>}
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="ptmOpens">Booking opens at (optional, Karachi time)</Label>
        <Input id="ptmOpens" type="datetime-local" {...form.register('opensAt')} />
      </div>
      {error && <p role="alert" className="text-sm text-destructive sm:col-span-3" data-testid="ptm-error">{error}</p>}
      <div className="sm:col-span-3">
        <Button type="submit" disabled={pending} data-testid="create-ptm">
          Create PTM
        </Button>
      </div>
    </form>
  );
}

export function SlotsForm({ eventId, teachers }: { eventId: string; teachers: { id: string; name: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [picked, setPicked] = useState<string[]>([]);
  const [startTime, setStartTime] = useState('10:00');
  const [endTime, setEndTime] = useState('12:00');
  const submit = () =>
    startTransition(async () => {
      const r = await generateSlots({ eventId, teacherIds: picked, startTime, endTime });
      setError(r.error);
      if (!r.error) {
        toast.success(`${r.count ?? 0} slots added.`);
        router.refresh();
      }
    });
  return (
    <div className="space-y-3 text-sm">
      <fieldset className="grid gap-1 sm:grid-cols-2">
        <legend className="mb-1 font-medium">Teachers taking part</legend>
        {teachers.map((t) => (
          <label key={t.id} className="flex items-center gap-2">
            <input type="checkbox" checked={picked.includes(t.id)} onChange={() => setPicked((cur) => (cur.includes(t.id) ? cur.filter((x) => x !== t.id) : [...cur, t.id]))} />
            {t.name}
          </label>
        ))}
      </fieldset>
      <div className="flex flex-wrap gap-3">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Slots from</span>
          <input type="time" value={startTime} onChange={(e) => setStartTime(e.target.value)} className="h-9 rounded-md border bg-background px-2" />
        </label>
        <label className="space-y-1">
          <span className="block text-muted-foreground">until</span>
          <input type="time" value={endTime} onChange={(e) => setEndTime(e.target.value)} className="h-9 rounded-md border bg-background px-2" />
        </label>
      </div>
      {error && <p role="alert" className="text-destructive">{error}</p>}
      <Button size="sm" disabled={pending || picked.length === 0} onClick={submit} data-testid="generate-slots">
        Generate slots
      </Button>
    </div>
  );
}
