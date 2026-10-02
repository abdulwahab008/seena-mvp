'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { refreshEligibility, resolveAdjustment, setSchemeThreshold } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

function useRun() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<{ error: string | null; summary?: string }>, success?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        toast.success(r.summary ?? success ?? 'Done.');
        router.refresh();
      }
    });
  return { pending, error, run };
}

export function ThresholdForm({ schemeId, current }: { schemeId: string; current: number | null }) {
  const { pending, error, run } = useRun();
  const [value, setValue] = useState(current === null ? '' : String(current));
  const submit = () => run(() => setSchemeThreshold({ schemeId, minPct: value.trim() === '' ? null : Number(value) }), 'Threshold saved.');
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-2">
        <Input aria-label="Minimum attendance %" type="number" step="0.01" className="h-8 w-24" placeholder="none" value={value} onChange={(e) => setValue(e.target.value)} />
        <Button size="sm" variant="outline" disabled={pending} onClick={submit}>
          Save
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function RefreshButton() {
  const { pending, error, run } = useRun();
  return (
    <div className="space-y-1">
      <Button size="sm" variant="outline" disabled={pending} onClick={() => run(refreshEligibility)} data-testid="refresh-eligibility">
        {pending ? 'Refreshing…' : 'Refresh eligibility now'}
      </Button>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}

export function ResolveForm({ taskId }: { taskId: string }) {
  const { pending, error, run } = useRun();
  const [note, setNote] = useState('');
  return (
    <div className="space-y-1">
      <div className="flex items-center gap-2">
        <Input aria-label="Resolution note" className="h-8 w-64" placeholder="What was done (e.g. credited on next challan)" value={note} onChange={(e) => setNote(e.target.value)} />
        <Button size="sm" disabled={pending} onClick={() => run(() => resolveAdjustment(taskId, note), 'Task resolved.')} data-testid="resolve-adjustment">
          Resolve
        </Button>
      </div>
      {error && <p role="alert" className="text-xs text-destructive">{error}</p>}
    </div>
  );
}
