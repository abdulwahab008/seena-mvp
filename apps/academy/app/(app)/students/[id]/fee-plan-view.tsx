'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { proposeFeePlanOverride, decideFeePlanOverride, removeFeePlanLine } from '../actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';

export type FeePlanLineRow = {
  id: string;
  headName: string;
  headCode: string;
  amountPaisa: number;
  pendingAmountPaisa: number | null;
  overrideReason: string | null;
  overrideStatus: string;
  frequency: string;
  effectiveTo: string | null;
};

function ProposeOverrideControl({ studentId, lineId }: { studentId: string; lineId: string }) {
  const [pending, startTransition] = useTransition();
  const [open, setOpen] = useState(false);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');

  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)}>
        Adjust
      </Button>
    );
  }

  const onSubmit = () => {
    if (!amount || !reason.trim()) {
      toast.error('Enter an amount and a reason.');
      return;
    }
    const fd = new FormData();
    fd.set('lineId', lineId);
    fd.set('amountRupees', amount);
    fd.set('reason', reason);
    startTransition(async () => {
      const result = await proposeFeePlanOverride(studentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Adjustment proposed — awaiting Principal approval.');
        setOpen(false);
        setAmount('');
        setReason('');
      }
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Input placeholder="New amount" type="number" className="h-9 w-28" value={amount} onChange={(e) => setAmount(e.target.value)} />
      <Input placeholder="Reason" className="h-9 w-40" value={reason} onChange={(e) => setReason(e.target.value)} />
      <Button type="button" size="sm" disabled={pending} onClick={onSubmit}>
        Propose
      </Button>
    </div>
  );
}

function DecideOverrideControls({ studentId, lineId }: { studentId: string; lineId: string }) {
  const [pending, startTransition] = useTransition();

  const decide = (approve: boolean) => {
    startTransition(async () => {
      const result = await decideFeePlanOverride(studentId, lineId, approve);
      if (result.error) toast.error(result.error);
      else toast.success(approve ? 'Adjustment approved.' : 'Adjustment rejected.');
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Button type="button" size="sm" disabled={pending} onClick={() => decide(true)}>
        Approve
      </Button>
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={() => decide(false)}>
        Reject
      </Button>
    </div>
  );
}

function RemoveButton({ studentId, lineId }: { studentId: string; lineId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await removeFeePlanLine(studentId, lineId);
      if (result.error) toast.error(result.error);
      else toast.success('Line removed from next billing period.');
    });
  };

  return (
    <Button type="button" size="sm" variant="ghost" disabled={pending} onClick={onClick}>
      Remove
    </Button>
  );
}

export function FeePlanView({
  studentId,
  lines,
  canAdjust,
  canApprove,
}: {
  studentId: string;
  lines: FeePlanLineRow[];
  canAdjust: boolean;
  canApprove: boolean;
}) {
  if (lines.length === 0) {
    return <p className="text-sm text-muted-foreground">No fee plan yet — one is built automatically once enrolled under a published fee structure.</p>;
  }

  return (
    <div className="space-y-2">
      {lines
        .filter((l) => !l.effectiveTo)
        .map((l) => (
          <Card key={l.id} data-testid={`fee-plan-line-${l.headCode}`}>
            <CardContent className="flex items-center justify-between gap-3 p-3 text-sm">
              <div>
                <p className="font-medium">
                  {l.headName} — PKR {(l.amountPaisa / 100).toLocaleString()} <span className="text-muted-foreground">({l.frequency})</span>
                </p>
                {l.overrideStatus === 'pending_approval' && (
                  <p className="text-xs text-muted-foreground" data-testid={`fee-plan-line-status-${l.headCode}`}>
                    Pending: PKR {((l.pendingAmountPaisa ?? 0) / 100).toLocaleString()} — {l.overrideReason}
                  </p>
                )}
              </div>
              <div className="flex items-center gap-2">
                {l.overrideStatus === 'pending_approval' ? (
                  canApprove && <DecideOverrideControls studentId={studentId} lineId={l.id} />
                ) : (
                  <>
                    {canAdjust && <ProposeOverrideControl studentId={studentId} lineId={l.id} />}
                    {canAdjust && <RemoveButton studentId={studentId} lineId={l.id} />}
                  </>
                )}
              </div>
            </CardContent>
          </Card>
        ))}
    </div>
  );
}
