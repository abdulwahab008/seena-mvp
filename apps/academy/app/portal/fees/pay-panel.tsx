'use client';

import { useState, useTransition } from 'react';
import { Button } from '@/components/ui/button';
import { initiatePayment } from './actions';
import type { Checkout } from '@/lib/payments/gateways';

const LABEL: Record<string, string> = { jazzcash: 'JazzCash', easypaisa: 'EasyPaisa', onelink: '1LINK' };

export type PayPanelProps = {
  challanId: string;
  challanNo: string;
  status: string;
  balancePaisa: number;
  underReconciliation: boolean;
  gateways: string[];
};

const pkr = (paisa: number) => `PKR ${(paisa / 100).toLocaleString('en-PK', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;

function submitRedirect(checkout: Extract<Checkout, { kind: 'redirect' }>) {
  const form = document.createElement('form');
  form.method = 'POST';
  form.action = checkout.url;
  for (const [name, value] of Object.entries(checkout.fields)) {
    const input = document.createElement('input');
    input.type = 'hidden';
    input.name = name;
    input.value = value;
    form.appendChild(input);
  }
  document.body.appendChild(form);
  form.submit();
}

export function PayPanel({ challanId, challanNo, status, balancePaisa, underReconciliation, gateways }: PayPanelProps) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [voucher, setVoucher] = useState<string | null>(null);

  if (status === 'paid') return null;

  if (underReconciliation) {
    return (
      <div className="rounded-md border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900" data-testid={`under-reconciliation-${challanNo}`}>
        Payment under reconciliation. Do not pay again — this challan will show as paid once the school confirms the payment with the bank.
        <Button size="sm" className="ml-3" disabled data-testid={`pay-disabled-${challanNo}`}>
          Pay online
        </Button>
      </div>
    );
  }

  if (gateways.length === 0) {
    return (
      <a className="inline-flex h-9 items-center rounded-md border px-3 text-sm hover:bg-accent" href={`/api/challans/${challanId}/pdf`} data-testid={`challan-pdf-${challanNo}`}>
        Download challan (PDF)
      </a>
    );
  }

  const pay = (gateway: string) =>
    startTransition(async () => {
      setError(null);
      const result = await initiatePayment({ challanId, gateway: gateway as 'jazzcash' | 'easypaisa' | 'onelink' });
      if (result.error !== null) {
        setError(result.error);
        return;
      }
      if (result.checkout.kind === 'voucher') setVoucher(result.checkout.reference);
      else submitRedirect(result.checkout);
    });

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-2">
        {gateways.map((g) => (
          <Button key={g} size="sm" disabled={pending} onClick={() => pay(g)} data-testid={`pay-${g}-${challanNo}`}>
            Pay {pkr(balancePaisa)} with {LABEL[g] ?? g}
          </Button>
        ))}
        <a className="text-sm underline-offset-2 hover:underline" href={`/api/challans/${challanId}/pdf`}>
          or download the challan
        </a>
      </div>
      {voucher && (
        <p className="text-sm" data-testid={`voucher-${challanNo}`}>
          In your bank app choose 1LINK bill payment and enter reference <strong className="font-mono">{voucher}</strong>.
        </p>
      )}
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
    </div>
  );
}
