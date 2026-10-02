'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { setAttendanceStatusWeight } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

// FR-G06: an unconfigured status keeps its built-in default (late=1,
// half_day=0.5) — this form only exists to override it, never to
// re-declare it, so the two inputs start at the resolved current value
// (whether that came from an override row or the fallback).
export function WeightForm({
  campusId,
  sessionId,
  lateWeight,
  halfDayWeight,
}: {
  campusId: string;
  sessionId: string;
  lateWeight: number;
  halfDayWeight: number;
}) {
  const [pending, startTransition] = useTransition();
  const [late, setLate] = useState(String(lateWeight));
  const [halfDay, setHalfDay] = useState(String(halfDayWeight));

  const save = (status: 'late' | 'half_day', weight: string) => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('status', status);
    fd.set('weight', weight);
    startTransition(async () => {
      const result = await setAttendanceStatusWeight({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Status weight saved.');
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-3 rounded-lg border p-4">
      <div className="space-y-1">
        <Label htmlFor="lateWeight">Late weight</Label>
        <Input
          id="lateWeight"
          type="number"
          min={0}
          max={1}
          step={0.05}
          className="w-24"
          value={late}
          onChange={(e) => setLate(e.target.value)}
          data-testid="attendance-weight-late"
        />
      </div>
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => save('late', late)} data-testid="attendance-weight-late-save">
        Save
      </Button>
      <div className="space-y-1">
        <Label htmlFor="halfDayWeight">Half-day weight</Label>
        <Input
          id="halfDayWeight"
          type="number"
          min={0}
          max={1}
          step={0.05}
          className="w-24"
          value={halfDay}
          onChange={(e) => setHalfDay(e.target.value)}
          data-testid="attendance-weight-half-day"
        />
      </div>
      <Button
        type="button"
        size="sm"
        variant="outline"
        disabled={pending}
        onClick={() => save('half_day', halfDay)}
        data-testid="attendance-weight-half-day-save"
      >
        Save
      </Button>
    </div>
  );
}
