'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { postLedgerEntry, reverseLedgerEntry } from '../actions';
import { LEDGER_ENTRY_TYPES, LEDGER_DIRECTIONS } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type LedgerEntryRow = {
  id: string;
  entryType: string;
  amountPaisa: number;
  direction: string;
  valueDate: string;
  reversalOfId: string | null;
  isReversed: boolean;
};

function PostEntryForm({ studentId, enrolmentId }: { studentId: string; enrolmentId: string }) {
  const [pending, startTransition] = useTransition();
  const [entryType, setEntryType] = useState<string>('charge');
  const [direction, setDirection] = useState<string>('debit');
  const [amount, setAmount] = useState('');

  const onSubmit = () => {
    if (!amount) {
      toast.error('Enter an amount.');
      return;
    }
    const fd = new FormData();
    fd.set('entryType', entryType);
    fd.set('direction', direction);
    fd.set('amountRupees', amount);
    startTransition(async () => {
      const result = await postLedgerEntry(studentId, enrolmentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Entry posted.');
        setAmount('');
      }
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-2 rounded-lg border p-3">
      <div className="space-y-1">
        <Label>Type</Label>
        <Select value={entryType} onValueChange={setEntryType}>
          <SelectTrigger data-testid="ledger-entry-type-trigger" className="w-36">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {LEDGER_ENTRY_TYPES.map((t) => (
              <SelectItem key={t} value={t}>
                {t.replace(/_/g, ' ')}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-1">
        <Label>Direction</Label>
        <Select value={direction} onValueChange={setDirection}>
          <SelectTrigger data-testid="ledger-direction-trigger" className="w-28">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {LEDGER_DIRECTIONS.map((d) => (
              <SelectItem key={d} value={d}>
                {d}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="ledger-amount">Amount (PKR)</Label>
        <Input id="ledger-amount" type="number" className="w-28" value={amount} onChange={(e) => setAmount(e.target.value)} />
      </div>
      <Button type="button" disabled={pending} onClick={onSubmit}>
        {pending ? 'Posting…' : 'Post entry'}
      </Button>
    </div>
  );
}

function ReverseControl({ studentId, ledgerId }: { studentId: string; ledgerId: string }) {
  const [pending, startTransition] = useTransition();
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');

  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)}>
        Reverse
      </Button>
    );
  }

  const onConfirm = () => {
    const fd = new FormData();
    fd.set('ledgerId', ledgerId);
    fd.set('reason', reason);
    startTransition(async () => {
      const result = await reverseLedgerEntry(studentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Entry reversed.');
        setOpen(false);
        setReason('');
      }
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Input placeholder="Reason (15+ chars)" className="h-9 w-52" value={reason} onChange={(e) => setReason(e.target.value)} />
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={onConfirm}>
        Confirm
      </Button>
    </div>
  );
}

export function LedgerView({
  studentId,
  enrolmentId,
  balancePaisa,
  entries,
  canPost,
  canReverse,
}: {
  studentId: string;
  enrolmentId: string;
  balancePaisa: number;
  entries: LedgerEntryRow[];
  canPost: boolean;
  canReverse: boolean;
}) {
  return (
    <div className="space-y-2">
      <p className="text-sm font-medium" data-testid="ledger-balance">
        Balance: PKR {(balancePaisa / 100).toLocaleString()}
      </p>
      {entries.length === 0 ? (
        <p className="text-sm text-muted-foreground">No ledger entries yet.</p>
      ) : (
        entries.map((e) => (
          <Card key={e.id} data-testid={`ledger-row-${e.id}`}>
            <CardContent className="flex items-center justify-between p-3 text-sm">
              <span>
                {e.entryType.replace(/_/g, ' ')} · {e.direction} PKR {(e.amountPaisa / 100).toLocaleString()} · {e.valueDate}
                {e.reversalOfId && ' (reversal)'}
                {e.isReversed && ' — reversed'}
              </span>
              {canReverse && !e.reversalOfId && !e.isReversed && <ReverseControl studentId={studentId} ledgerId={e.id} />}
            </CardContent>
          </Card>
        ))
      )}
      {canPost && <PostEntryForm studentId={studentId} enrolmentId={enrolmentId} />}
    </div>
  );
}
