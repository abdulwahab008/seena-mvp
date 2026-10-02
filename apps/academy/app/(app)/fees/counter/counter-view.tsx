'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { lookupChallan, collectCashPayment, printReceipt, type PrintResult } from './actions';
import { FEE_PAYMENT_MODES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type LookupState = {
  challanId: string;
  studentName: string;
  grNumber: string;
  netPaisa: number;
  outstandingPaisa: number;
  status: string;
};

export function CounterView() {
  const [pending, startTransition] = useTransition();
  const [challanNo, setChallanNo] = useState('');
  const [lookup, setLookup] = useState<LookupState | null>(null);
  const [amount, setAmount] = useState('');
  const [mode, setMode] = useState<string>('cash');
  const [idemKey, setIdemKey] = useState<string | null>(null);
  const [receiptId, setReceiptId] = useState<string | null>(null);
  const [printResult, setPrintResult] = useState<PrintResult | null>(null);

  const onLookup = () => {
    if (!challanNo) {
      toast.error('Scan or enter a challan number.');
      return;
    }
    const fd = new FormData();
    fd.set('challanNo', challanNo);
    startTransition(async () => {
      const result = await lookupChallan({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        setLookup(null);
        return;
      }
      setLookup({
        challanId: result.challanId!,
        studentName: result.studentName!,
        grNumber: result.grNumber!,
        netPaisa: result.netPaisa!,
        outstandingPaisa: result.outstandingPaisa!,
        status: result.status!,
      });
      // AC: the amount field is pre-filled with the (outstanding) net
      // payable — the accountant can still adjust it for a partial payment.
      setAmount((result.outstandingPaisa! / 100).toString());
      // A fresh idempotency key per lookup: reused across retries of the
      // SAME collection attempt (a flaky connection resending this exact
      // click), regenerated only when starting a genuinely new one.
      setIdemKey(crypto.randomUUID());
      setReceiptId(null);
      setPrintResult(null);
    });
  };

  const onCollect = () => {
    if (!lookup || !idemKey) return;
    if (!amount) {
      toast.error('Enter an amount.');
      return;
    }
    const fd = new FormData();
    fd.set('challanId', lookup.challanId);
    fd.set('amountRupees', amount);
    fd.set('mode', mode);
    fd.set('clientIdempotencyKey', idemKey);
    startTransition(async () => {
      const result = await collectCashPayment({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success(result.isReplay ? 'Already collected — showing the original receipt.' : 'Payment collected.');
      setReceiptId(result.receiptId!);
      setPrintResult(null);
    });
  };

  const onPrint = () => {
    if (!receiptId) return;
    const fd = new FormData();
    fd.set('receiptId', receiptId);
    startTransition(async () => {
      const result = await printReceipt({ error: null }, fd);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setPrintResult(result);
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="counter-challan-no">Challan number</Label>
          <Input
            id="counter-challan-no"
            data-testid="counter-challan-no-input"
            value={challanNo}
            onChange={(e) => setChallanNo(e.target.value)}
            className="w-56"
          />
        </div>
        <Button type="button" disabled={pending} onClick={onLookup} data-testid="counter-lookup-button">
          {pending ? 'Looking up…' : 'Look up'}
        </Button>
      </div>

      {lookup && (
        <Card data-testid="counter-lookup-result">
          <CardContent className="space-y-3 p-4 text-sm">
            <p className="font-medium">
              {lookup.studentName} · GR {lookup.grNumber}
            </p>
            <p className="text-muted-foreground">
              Net payable PKR {(lookup.netPaisa / 100).toLocaleString()} · Outstanding PKR{' '}
              {(lookup.outstandingPaisa / 100).toLocaleString()} · {lookup.status}
            </p>
            <div className="flex flex-wrap items-end gap-2">
              <div className="space-y-1">
                <Label htmlFor="counter-amount">Amount (PKR)</Label>
                <Input
                  id="counter-amount"
                  type="number"
                  data-testid="counter-amount-input"
                  className="w-28"
                  value={amount}
                  onChange={(e) => setAmount(e.target.value)}
                />
              </div>
              <div className="space-y-1">
                <Label>Mode</Label>
                <Select value={mode} onValueChange={setMode}>
                  <SelectTrigger data-testid="counter-mode-trigger" className="w-36">
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
              <Button type="button" disabled={pending} onClick={onCollect} data-testid="counter-collect-button">
                {pending ? 'Collecting…' : 'Collect payment'}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}

      {receiptId && (
        <Card data-testid="counter-receipt-card">
          <CardContent className="space-y-2 p-4 text-sm">
            <Button type="button" variant="outline" disabled={pending} onClick={onPrint} data-testid="counter-print-button">
              {pending ? 'Printing…' : printResult ? 'Reprint' : 'Print receipt'}
            </Button>
            {printResult && (
              <div data-testid="counter-print-result" className="space-y-1 rounded-md border p-3">
                {printResult.isDuplicate && (
                  <p className="font-semibold text-destructive" data-testid="counter-duplicate-watermark">
                    DUPLICATE
                  </p>
                )}
                <p>Receipt {printResult.receiptNo}</p>
                <p>
                  {printResult.studentName} · GR {printResult.grNumber}
                </p>
                <p>{printResult.amountWords}</p>
                <p className="text-muted-foreground">
                  Outstanding after this payment: PKR {(printResult.postPaymentOutstandingPaisa! / 100).toLocaleString()}
                </p>
              </div>
            )}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
