'use client';

import { useActionState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { addLine, approve, createDraft, markPaid, removeLine, revise, type SettlementState } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: SettlementState = { error: null };

function useSuccess(state: SettlementState) {
  const router = useRouter();
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
}

function SimpleAction({ action, exitId, settlementId, label, testId, variant }: { action: (p: SettlementState, f: FormData) => Promise<SettlementState>; exitId: string; settlementId?: string; label: string; testId: string; variant?: 'default' | 'outline' }) {
  const [state, run, pending] = useActionState(action, initial);
  useSuccess(state);
  return (
    <form action={run} className="inline-flex flex-col gap-1">
      <input type="hidden" name="exitId" value={exitId} />
      {settlementId && <input type="hidden" name="settlementId" value={settlementId} />}
      <Button type="submit" disabled={pending} variant={variant ?? 'default'} data-testid={testId}>
        {label}
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive" data-testid={`${testId}-error`}>{state.error}</span>}
    </form>
  );
}

export const ComputeButton = (p: { exitId: string; label: string }) => <SimpleAction action={createDraft} exitId={p.exitId} label={p.label} testId="compute-settlement" />;
export const ApproveButton = (p: { exitId: string; settlementId: string }) => <SimpleAction action={approve} exitId={p.exitId} settlementId={p.settlementId} label="Approve and freeze" testId="approve-settlement" />;
export const PaidButton = (p: { exitId: string; settlementId: string }) => <SimpleAction action={markPaid} exitId={p.exitId} settlementId={p.settlementId} label="Mark as paid" testId="mark-paid" />;
export const ReviseButton = (p: { exitId: string; settlementId: string }) => <SimpleAction action={revise} exitId={p.exitId} settlementId={p.settlementId} label="Revise (new version)" testId="revise-settlement" variant="outline" />;

export function RemoveLineButton({ exitId, lineId }: { exitId: string; lineId: string }) {
  const [state, run, pending] = useActionState(removeLine, initial);
  useSuccess(state);
  return (
    <form action={run} className="inline">
      <input type="hidden" name="exitId" value={exitId} />
      <input type="hidden" name="lineId" value={lineId} />
      <Button type="submit" size="sm" variant="ghost" disabled={pending}>
        Remove
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}

export function AddLineForm({ exitId, settlementId }: { exitId: string; settlementId: string }) {
  const [state, run, pending] = useActionState(addLine, initial);
  useSuccess(state);
  return (
    <form action={run} className="grid gap-3 sm:grid-cols-5" data-testid="add-line-form">
      <input type="hidden" name="exitId" value={exitId} />
      <input type="hidden" name="settlementId" value={settlementId} />
      <div className="space-y-1">
        <Label htmlFor="lineType">Type</Label>
        <select id="lineType" name="lineType" className="h-9 w-full rounded-md border bg-background px-2 text-sm">
          <option value="gratuity">Gratuity</option>
          <option value="asset_recovery">Asset recovery</option>
          <option value="advance_recovery">Advance recovery</option>
          <option value="other">Other</option>
        </select>
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor="lineDescription">Description</Label>
        <Input id="lineDescription" name="description" required />
      </div>
      <div className="space-y-1">
        <Label htmlFor="lineAmount">Amount (PKR)</Label>
        <Input id="lineAmount" name="amount" inputMode="decimal" required />
      </div>
      <div className="space-y-1">
        <Label htmlFor="lineSign">Effect</Label>
        <select id="lineSign" name="sign" className="h-9 w-full rounded-md border bg-background px-2 text-sm">
          <option value="1">Adds to dues</option>
          <option value="-1">Deduction</option>
        </select>
      </div>
      {state.error && <p role="alert" className="text-sm text-destructive sm:col-span-5">{state.error}</p>}
      <div className="sm:col-span-5">
        <Button type="submit" size="sm" disabled={pending} data-testid="add-line">
          Add line
        </Button>
      </div>
    </form>
  );
}
