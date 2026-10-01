'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { invigilationExclusionSchema, type InvigilationExclusionInput } from '@/lib/validation';
import { blockedReasonText } from '@/lib/exams/invigilation-errors';
import { addDuty, addExclusion, notifyRoster, removeDuty, removeExclusion, runAssignment, type AssignReport } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export type StaffOption = { userId: string; name: string };

export function RunPanel({ datesheetId, slotLabels }: { datesheetId: string; slotLabels: Record<string, string> }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [report, setReport] = useState<AssignReport | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-3">
        <Button
          disabled={pending}
          data-testid="run-assignment"
          onClick={() =>
            startTransition(async () => {
              const r = await runAssignment(datesheetId);
              setError(r.error);
              setReport(r.report ?? null);
              if (!r.error) {
                toast.success(`${r.report?.assigned_now ?? 0} duties assigned.`);
                router.refresh();
              }
            })
          }
        >
          Auto-assign invigilators
        </Button>
        <Button
          variant="outline"
          disabled={pending}
          data-testid="notify-roster"
          onClick={() =>
            startTransition(async () => {
              const r = await notifyRoster(datesheetId);
              setError(r.error);
              setNotice(r.error ? null : `${r.notified ?? 0} staff notified in-app.`);
            })
          }
        >
          Send roster to staff
        </Button>
        {notice && <span className="text-sm text-muted-foreground" data-testid="notify-result">{notice}</span>}
      </div>
      {error && <p role="alert" className="text-sm text-destructive">{error}</p>}
      {report && (
        <div className="space-y-2 rounded-md border p-3 text-sm" data-testid="assign-report">
          <p>
            {report.assigned_now} duties assigned. Load spread: {report.spread.min} to {report.spread.max} duties per person.
            {report.substitution_tasks > 0 ? ` ${report.substitution_tasks} duty(ies) need a substitute.` : ''}
          </p>
          {report.understaffed.length === 0 ? (
            <p className="text-muted-foreground">Every paper has its configured invigilators.</p>
          ) : (
            <div role="alert" className="space-y-1 text-destructive" data-testid="understaffed">
              <p className="font-medium">Under-staffed papers — not enough eligible staff:</p>
              {report.understaffed.map((u) => (
                <p key={u.slot_id} data-testid="understaffed-slot">
                  {slotLabels[u.slot_id] ?? u.slot_id}: {u.assigned} of {u.required} (short by {u.shortfall}).{' '}
                  {Object.entries(u.pool)
                    .filter(([k, n]) => k !== 'available' && n > 0)
                    .map(([k, n]) => `${n} ${blockedReasonText(k)}`)
                    .join('; ')}
                </p>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export function AddDutyForm({ slotId, staff }: { slotId: string; staff: StaffOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [staffUserId, setStaffUserId] = useState('');
  return (
    <div className="flex flex-wrap items-center gap-2">
      <select aria-label="Add invigilator" className="h-8 rounded-md border bg-background px-2 text-sm" value={staffUserId} onChange={(e) => setStaffUserId(e.target.value)}>
        <option value="">Add an invigilator…</option>
        {staff.map((s) => (
          <option key={s.userId} value={s.userId}>
            {s.name}
          </option>
        ))}
      </select>
      <Button
        size="sm"
        variant="outline"
        disabled={pending || !staffUserId}
        onClick={() =>
          startTransition(async () => {
            const r = await addDuty({ slotId, staffUserId });
            setError(r.error);
            if (!r.error) {
              setStaffUserId('');
              router.refresh();
            }
          })
        }
      >
        Add
      </Button>
      {error && <span role="alert" className="text-xs text-destructive" data-testid="add-duty-error">{error}</span>}
    </div>
  );
}

export function RemoveDutyButton({ dutyId }: { dutyId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span>
      <Button
        size="sm"
        variant="ghost"
        disabled={pending}
        onClick={() =>
          startTransition(async () => {
            const r = await removeDuty(dutyId);
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

export function ExclusionForm({ examTermId, staff }: { examTermId: string; staff: StaffOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<InvigilationExclusionInput>({ resolver: zodResolver(invigilationExclusionSchema), defaultValues: { examTermId, staffUserId: '', date: '', reason: '' } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await addExclusion(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Exclusion added.');
        form.reset({ examTermId, staffUserId: '', date: '', reason: '' });
        router.refresh();
      }
    }),
  );
  const firstError = Object.values(form.formState.errors)[0]?.message as string | undefined;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-5" noValidate>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="exStaff">Staff member</Label>
        <select id="exStaff" className="h-10 w-full rounded-md border bg-background px-2 text-sm" {...form.register('staffUserId')}>
          <option value="">Choose…</option>
          {staff.map((s) => (
            <option key={s.userId} value={s.userId}>
              {s.name}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="exDate">Unavailable on</Label>
        <Input id="exDate" type="date" {...form.register('date')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="exReason">Reason</Label>
        <Input id="exReason" {...form.register('reason')} />
      </div>
      <div className="flex items-end">
        <Button type="submit" variant="outline" disabled={pending} data-testid="add-exclusion">
          Add exclusion
        </Button>
      </div>
      {(error || firstError) && <p role="alert" className="text-sm text-destructive sm:col-span-5">{error ?? firstError}</p>}
    </form>
  );
}

export function RemoveExclusionButton({ id }: { id: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await removeExclusion(id);
          if (!r.error) router.refresh();
        })
      }
    >
      Remove
    </Button>
  );
}
