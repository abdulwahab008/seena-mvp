'use client';

import { useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { setAttendancePolicy, previewAttendanceStatus } from './actions';
import { setAttendancePolicySchema, ATTENDANCE_MODES, type SetAttendancePolicyInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type PolicyRow = {
  startTime: string;
  lateThresholdMinutes: number;
  lockWindowHours: number;
  mode: string;
  saturdayWorking: boolean;
} | null;

function StatusPreview({ campusId, sessionId }: { campusId: string; sessionId: string }) {
  const [pending, startTransition] = useTransition();
  const [time, setTime] = useState('08:14');
  const [status, setStatus] = useState<string | null>(null);

  const onCheck = () => {
    startTransition(async () => {
      const result = await previewAttendanceStatus(campusId, sessionId, time);
      if (result.error) toast.error(result.error);
      else setStatus(result.status);
    });
  };

  return (
    <div className="flex items-center gap-2 rounded-lg border p-3 text-sm" data-testid="attendance-status-preview">
      <Label htmlFor="preview-time" className="whitespace-nowrap">
        Marked at
      </Label>
      <Input id="preview-time" type="time" className="h-8 w-28" value={time} onChange={(e) => setTime(e.target.value)} />
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onCheck} data-testid="attendance-status-preview-check">
        Check status
      </Button>
      {status && (
        <span data-testid="attendance-status-preview-result" className="font-medium">
          {status}
        </span>
      )}
    </div>
  );
}

export function PolicyForm({ campusId, sessionId, current }: { campusId: string; sessionId: string; current: PolicyRow }) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    formState: { errors },
  } = useForm<SetAttendancePolicyInput>({
    resolver: zodResolver(setAttendancePolicySchema),
    defaultValues: {
      campusId,
      sessionId,
      mode: (current?.mode as 'daily' | 'period') ?? 'daily',
      startTime: current?.startTime ?? '08:00',
      lateThresholdMinutes: current?.lateThresholdMinutes ?? 15,
      lockWindowHours: current?.lockWindowHours ?? 24,
      saturdayWorking: current?.saturdayWorking ?? false,
    },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('mode', values.mode);
    fd.set('startTime', values.startTime);
    fd.set('lateThresholdMinutes', String(values.lateThresholdMinutes));
    if (values.halfDayCutoffTime) fd.set('halfDayCutoffTime', values.halfDayCutoffTime);
    fd.set('lockWindowHours', String(values.lockWindowHours));
    if (values.minAttendancePct !== undefined) fd.set('minAttendancePct', String(values.minAttendancePct));
    fd.set('saturdayWorking', String(values.saturdayWorking));

    startTransition(async () => {
      const result = await setAttendancePolicy({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Attendance policy saved.');
    });
  });

  return (
    <div className="space-y-4">
      {!current && (
        <p className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800" data-testid="attendance-policy-unconfigured">
          Attendance policy not configured for this session — contact your Principal.
        </p>
      )}
      <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
        <div className="space-y-1">
          <Label htmlFor="mode">Mode</Label>
          <Controller
            control={control}
            name="mode"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger id="mode" data-testid="attendance-mode-trigger">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  {ATTENDANCE_MODES.map((m) => (
                    <SelectItem key={m} value={m}>
                      {m}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="startTime">Start time</Label>
          <Input id="startTime" type="time" {...register('startTime')} data-testid="attendance-start-time" />
          {errors.startTime && <p className="text-xs text-destructive">{errors.startTime.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="lateThresholdMinutes">Late threshold (min)</Label>
          <Input id="lateThresholdMinutes" type="number" min={0} {...register('lateThresholdMinutes')} data-testid="attendance-late-threshold" />
          {errors.lateThresholdMinutes && <p className="text-xs text-destructive">{errors.lateThresholdMinutes.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="lockWindowHours">Lock window (hrs)</Label>
          <Input id="lockWindowHours" type="number" min={1} {...register('lockWindowHours')} data-testid="attendance-lock-window" />
          {errors.lockWindowHours && <p className="text-xs text-destructive">{errors.lockWindowHours.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="halfDayCutoffTime">Half-day cutoff (optional)</Label>
          <Input id="halfDayCutoffTime" type="time" {...register('halfDayCutoffTime')} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="minAttendancePct">Min attendance % (optional)</Label>
          <Input id="minAttendancePct" type="number" min={0} max={100} {...register('minAttendancePct')} />
        </div>
        <label className="flex items-end gap-2 self-end pb-2 text-sm">
          <input type="checkbox" {...register('saturdayWorking')} />
          Saturday is a working day
        </label>
        <Button type="submit" disabled={pending} className="col-span-full w-fit" data-testid="attendance-policy-save">
          {pending ? 'Saving…' : 'Save policy'}
        </Button>
      </form>
      {current && <StatusPreview campusId={campusId} sessionId={sessionId} />}
    </div>
  );
}
