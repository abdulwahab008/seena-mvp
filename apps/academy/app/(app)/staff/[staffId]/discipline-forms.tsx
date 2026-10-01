'use client';

import { useActionState, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { issueDisciplinaryAction, reinstateStaff, supersedeDisciplinaryRecord, type DisciplineState } from './discipline-actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const initial: DisciplineState = { error: null };
const selectCls = 'h-9 w-full rounded-md border bg-background px-2 text-sm';

function useSuccess(state: DisciplineState) {
  const router = useRouter();
  useEffect(() => {
    if (state.message) {
      toast.success(state.message);
      router.refresh();
    }
  }, [state, router]);
}

export function IssueForm({ staffId, canTerminate }: { staffId: string; canTerminate: boolean }) {
  const [state, action, pending] = useActionState(issueDisciplinaryAction, initial);
  const [type, setType] = useState('warning');
  useSuccess(state);
  return (
    <form action={action} className="space-y-3" data-testid="issue-disciplinary-form">
      <input type="hidden" name="staffId" value={staffId} />
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="space-y-1">
          <Label htmlFor="actionType">Type of action</Label>
          <select id="actionType" name="actionType" value={type} onChange={(e) => setType(e.target.value)} className={selectCls}>
            <option value="warning">Warning</option>
            <option value="show_cause">Show-cause notice</option>
            <option value="inquiry">Inquiry</option>
            <option value="suspension">Suspension</option>
            {canTerminate && <option value="termination">Termination (misconduct)</option>}
          </select>
        </div>
        {type === 'show_cause' && (
          <div className="space-y-1">
            <Label htmlFor="responseDays">Days allowed to respond</Label>
            <Input id="responseDays" name="responseDays" type="number" min={1} max={60} defaultValue={7} />
          </div>
        )}
        {type === 'suspension' && (
          <>
            <div className="space-y-1">
              <Label htmlFor="suspendFrom">Suspended from</Label>
              <Input id="suspendFrom" name="suspendFrom" type="date" />
            </div>
            <div className="space-y-1">
              <Label htmlFor="suspendTo">Suspended until</Label>
              <Input id="suspendTo" name="suspendTo" type="date" />
            </div>
          </>
        )}
      </div>
      <div className="space-y-1">
        <Label htmlFor="description">What happened</Label>
        <textarea id="description" name="description" rows={3} required className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
      </div>
      {state.error && <p role="alert" className="text-sm text-destructive" data-testid="disciplinary-error">{state.error}</p>}
      <Button type="submit" disabled={pending} data-testid="issue-disciplinary">
        Record action
      </Button>
      <p className="text-xs text-muted-foreground">Entries are permanent and time-stamped by the server. Mistakes are corrected by adding a new entry, never by editing.</p>
    </form>
  );
}

export function CorrectionForm({ staffId, recordId, isShowCause, isSuspension }: { staffId: string; recordId: string; isShowCause: boolean; isSuspension: boolean }) {
  const [state, action, pending] = useActionState(supersedeDisciplinaryRecord, initial);
  const [open, setOpen] = useState(false);
  useSuccess(state);
  useEffect(() => {
    if (state.message) setOpen(false);
  }, [state]);
  if (!open)
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)} data-testid="open-correction">
        {isShowCause ? 'Record response or outcome' : 'Add correction or outcome'}
      </Button>
    );
  return (
    <form action={action} className="space-y-2 rounded-md border p-3" data-testid="correction-form">
      <input type="hidden" name="recordId" value={recordId} />
      <input type="hidden" name="staffId" value={staffId} />
      {isShowCause && (
        <div className="space-y-1">
          <Label>Staff member&apos;s response</Label>
          <textarea name="staffResponse" rows={3} aria-label="Staff response" className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
        </div>
      )}
      <div className="space-y-1">
        <Label>Outcome</Label>
        <Input name="outcome" aria-label="Outcome" />
      </div>
      <div className="space-y-1">
        <Label>Corrected description (leave empty to keep the original)</Label>
        <textarea name="description" rows={2} aria-label="Corrected description" className="w-full rounded-md border bg-background px-3 py-2 text-sm" />
      </div>
      {isSuspension && (
        <div className="grid gap-2 sm:grid-cols-2">
          <Input name="suspendFrom" type="date" aria-label="New suspension start" />
          <Input name="suspendTo" type="date" aria-label="New suspension end" />
        </div>
      )}
      {state.error && <p role="alert" className="text-sm text-destructive">{state.error}</p>}
      <div className="flex gap-2">
        <Button type="submit" size="sm" disabled={pending} data-testid="save-correction">
          Add entry
        </Button>
        <Button type="button" size="sm" variant="ghost" onClick={() => setOpen(false)}>
          Cancel
        </Button>
      </div>
    </form>
  );
}

export function ReinstateForm({ staffId, recordId }: { staffId: string; recordId: string }) {
  const [state, action, pending] = useActionState(reinstateStaff, initial);
  useSuccess(state);
  return (
    <form action={action} className="flex items-center gap-2">
      <input type="hidden" name="recordId" value={recordId} />
      <input type="hidden" name="staffId" value={staffId} />
      <Input name="note" placeholder="Reason" aria-label="Reinstatement note" className="h-8 w-48" />
      <Button type="submit" size="sm" variant="outline" disabled={pending} data-testid="reinstate">
        Lift suspension
      </Button>
      {state.error && <span role="alert" className="text-xs text-destructive">{state.error}</span>}
    </form>
  );
}
