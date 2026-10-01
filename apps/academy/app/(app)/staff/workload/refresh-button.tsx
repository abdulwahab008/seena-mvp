'use client';

import { useActionState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { refreshWorkload, type WorkloadState } from './actions';
import { Button } from '@/components/ui/button';

const initial: WorkloadState = { error: null };

export function RefreshButton({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(refreshWorkload, initial);
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
  return (
    <form action={action} className="inline-flex flex-col gap-1">
      <input type="hidden" name="campus" value={campusId} />
      <Button type="submit" variant="outline" disabled={pending} data-testid="refresh-workload">
        Refresh now
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}
