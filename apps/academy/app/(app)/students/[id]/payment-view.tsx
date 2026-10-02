'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { recordPayment } from '../actions';
import { FEE_PAYMENT_MODES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type PaymentAllocationRow = { challanNo: string; feeHeadCode: string; amountPaisa: number };
export type PaymentRow = {
  id: string;
  amountPaisa: number;
  mode: string;
  valueDate: string;
  referenceNo: string | null;
  allocations: PaymentAllocationRow[];
};

function RecordPaymentForm({ studentId, enrolmentId }: { studentId: string; enrolmentId: string }) {
  const [pending, startTransition] = useTransition();
  const [amount, setAmount] = useState('');
  const [mode, setMode] = useState<string>('cash');
  const [referenceNo, setReferenceNo] = useState('');

  const onSubmit = () => {
    if (!amount) {
      toast.error('Enter an amount.');
      return;
    }
    const fd = new FormData();
    fd.set('amountRupees', amount);
    fd.set('mode', mode);
    if (referenceNo) fd.set('referenceNo', referenceNo);
    startTransition(async () => {
      const result = await recordPayment(studentId, enrolmentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Payment recorded and allocated.');
        setAmount('');
        setReferenceNo('');
      }
    });
  };

  return (
    <div className="flex flex-wrap items-end gap-2 rounded-lg border p-3">
      <div className="space-y-1">
        <Label htmlFor="payment-amount">Amount (PKR)</Label>
        <Input
          id="payment-amount"
          type="number"
          className="w-28"
          value={amount}
          onChange={(e) => setAmount(e.target.value)}
          data-testid="payment-amount-input"
        />
      </div>
      <div className="space-y-1">
        <Label>Mode</Label>
        <Select value={mode} onValueChange={setMode}>
          <SelectTrigger data-testid="payment-mode-trigger" className="w-36">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {FEE_PAYMENT_MODES.map((m) => (
              <SelectItem key={m} value={m}>
                {m.replace(/_/g, ' ')}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="payment-reference">Reference</Label>
        <Input
          id="payment-reference"
          className="w-36"
          value={referenceNo}
          onChange={(e) => setReferenceNo(e.target.value)}
          placeholder="optional"
        />
      </div>
      <Button type="button" disabled={pending} onClick={onSubmit} data-testid="record-payment-button">
        {pending ? 'Recording…' : 'Record payment'}
      </Button>
    </div>
  );
}

export function PaymentView({
  studentId,
  enrolmentId,
  payments,
  canRecord,
}: {
  studentId: string;
  enrolmentId: string;
  payments: PaymentRow[];
  canRecord: boolean;
}) {
  return (
    <div className="space-y-2">
      {payments.length === 0 ? (
        <p className="text-sm text-muted-foreground">No payments recorded yet.</p>
      ) : (
        payments.map((p) => {
          const allocated = p.allocations.reduce((sum, a) => sum + a.amountPaisa, 0);
          const unallocated = p.amountPaisa - allocated;
          return (
            <Card key={p.id} data-testid={`payment-row-${p.id}`}>
              <CardContent className="space-y-1 p-3 text-sm">
                <div className="flex items-center justify-between">
                  <span>
                    {p.mode.replace(/_/g, ' ')} · PKR {(p.amountPaisa / 100).toLocaleString()} · {p.valueDate}
                    {p.referenceNo && ` · ${p.referenceNo}`}
                  </span>
                </div>
                {p.allocations.length > 0 && (
                  <p className="text-xs text-muted-foreground">
                    Applied to: {p.allocations.map((a) => `${a.challanNo} (${a.feeHeadCode} PKR ${(a.amountPaisa / 100).toLocaleString()})`).join(', ')}
                  </p>
                )}
                {unallocated > 0 && (
                  <p className="text-xs text-muted-foreground" data-testid={`payment-credit-${p.id}`}>
                    PKR {(unallocated / 100).toLocaleString()} held as advance credit, applied automatically to the next challan.
                  </p>
                )}
              </CardContent>
            </Card>
          );
        })
      )}
      {canRecord && <RecordPaymentForm studentId={studentId} enrolmentId={enrolmentId} />}
    </div>
  );
}
