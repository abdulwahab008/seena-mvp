'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { acknowledgeVariance, clearAcknowledgement, refreshVariance } from './actions';
import { Button } from '@/components/ui/button';

function useRun() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const run = (fn: () => Promise<{ error: string | null }>, ok?: string) =>
    startTransition(async () => {
      const r = await fn();
      setError(r.error);
      if (!r.error) {
        if (ok) toast.success(ok);
        router.refresh();
      }
    });
  return { pending, error, run };
}

export function RefreshButton({ campusId }: { campusId: string }) {
  const { pending, error, run } = useRun();
  return (
    <span className="flex items-center gap-2">
      <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => refreshVariance(campusId), 'Variance refreshed.')} data-testid="refresh-variance">
        Refresh now
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}

export function AckControl({ sectionId, subjectId, reason }: { sectionId: string; subjectId: string; reason: string | null }) {
  const { pending, error, run } = useRun();
  const [text, setText] = useState('');
  if (reason) {
    return (
      <span className="text-xs text-muted-foreground" data-testid="ack-reason">
        Acknowledged: {reason}{' '}
        <button type="button" className="underline" disabled={pending} onClick={() => run(() => clearAcknowledgement(sectionId, subjectId))}>
          clear
        </button>
      </span>
    );
  }
  return (
    <span className="flex flex-wrap items-center gap-1">
      <input aria-label="Reason" placeholder="Reason (e.g. floods)" value={text} onChange={(e) => setText(e.target.value)} className="h-8 w-44 rounded-md border bg-background px-2 text-xs" />
      <Button size="sm" variant="outline" disabled={pending} onClick={() => run(() => acknowledgeVariance({ sectionId, subjectId, reason: text }), 'Acknowledged.')} data-testid="acknowledge">
        Acknowledge
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
