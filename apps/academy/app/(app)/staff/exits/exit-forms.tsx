'use client';

import { useActionState, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { clearItem, completeExit, initiateExit, waiveItem, type ExitState } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: ExitState = { error: null };

function useSuccess(state: ExitState, then?: (s: ExitState) => void) {
  const router = useRouter();
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
      then?.(state);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state, router]);
}

export function InitiateExitForm({ staffId }: { staffId: string }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(initiateExit, initial);
  const [type, setType] = useState('resignation');
  useSuccess(state, (s) => {
    if (s.exitId) router.push(`/staff/exits/${s.exitId}`);
  });
  return (
    <form action={action} className="space-y-3" data-testid="initiate-exit-form">
      <input type="hidden" name="staffId" value={staffId} />
      <div className="grid gap-3 sm:grid-cols-3">
        <div className="space-y-1">
          <Label htmlFor="exitType">Type of exit</Label>
          <select id="exitType" name="exitType" value={type} onChange={(e) => setType(e.target.value)} className="h-9 w-full rounded-md border bg-background px-2 text-sm">
            <option value="resignation">Resignation</option>
            <option value="termination">Termination</option>
            <option value="contract_expiry">Contract expiry</option>
            <option value="retirement">Retirement</option>
            <option value="death">Death</option>
          </select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="noticeDate">Notice given on</Label>
          <Input id="noticeDate" name="noticeDate" type="date" />
        </div>
        <div className="space-y-1">
          <Label htmlFor="lastWorkingDate">Last working date</Label>
          <Input id="lastWorkingDate" name="lastWorkingDate" type="date" required />
        </div>
      </div>
      <div className="space-y-1">
        <Label htmlFor="reason">Reason (optional)</Label>
        <Input id="reason" name="reason" />
      </div>
      {state.error && <p role="alert" className="text-sm text-destructive" data-testid="exit-error">{state.error}</p>}
      <Button type="submit" disabled={pending} data-testid="start-exit">
        Start exit
      </Button>
    </form>
  );
}

export function ClearButton({ exitId, itemCode }: { exitId: string; itemCode: string }) {
  const [state, action, pending] = useActionState(clearItem, initial);
  useSuccess(state);
  return (
    <form action={action} className="inline-flex items-center gap-2">
      <input type="hidden" name="exitId" value={exitId} />
      <input type="hidden" name="itemCode" value={itemCode} />
      <Button type="submit" size="sm" disabled={pending} data-testid={`clear-${itemCode}`}>
        Mark cleared
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}

export function WaiveForm({ exitId, itemCode }: { exitId: string; itemCode: string }) {
  const [state, action, pending] = useActionState(waiveItem, initial);
  const [open, setOpen] = useState(false);
  useSuccess(state, () => setOpen(false));
  if (!open)
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)} data-testid={`open-waive-${itemCode}`}>
        Waive
      </Button>
    );
  return (
    <form action={action} className="flex flex-wrap items-center gap-2">
      <input type="hidden" name="exitId" value={exitId} />
      <input type="hidden" name="itemCode" value={itemCode} />
      <Input name="reason" placeholder="Reason (at least 10 characters)" aria-label={`Waiver reason for ${itemCode}`} className="h-8 w-64" required />
      <Button type="submit" size="sm" disabled={pending} data-testid={`waive-${itemCode}`}>
        Record waiver
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}

export function CompleteExitForm({ exitId }: { exitId: string }) {
  const [state, action, pending] = useActionState(completeExit, initial);
  useSuccess(state);
  return (
    <form action={action} className="space-y-2">
      <input type="hidden" name="exitId" value={exitId} />
      <Button type="submit" disabled={pending} data-testid="complete-exit">
        Complete exit and revoke access
      </Button>
      {state.error && <p role="alert" className="text-sm text-destructive" data-testid="complete-error">{state.error}</p>}
    </form>
  );
}
