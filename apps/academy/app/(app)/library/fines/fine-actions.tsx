'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { formatPkrCompact } from '@/lib/format-money';
import { settleFines, waiveFines } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';

export function FineActions({ borrowerId, name }: { borrowerId: string; name: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');
  const [receipt, setReceipt] = useState('');
  const [error, setError] = useState<string | null>(null);

  const done = (verb: string, amount?: number) => {
    toast.success(`${verb} ${formatPkrCompact(amount ?? 0)} for ${name}.`);
    router.refresh();
  };

  return (
    <div className="flex flex-wrap items-center gap-2" data-testid="fine-actions">
      <Input aria-label={`Receipt reference for ${name}`} placeholder="Receipt id (optional)" className="h-8 w-44 text-xs" value={receipt} onChange={(e) => setReceipt(e.target.value)} />
      <Button
        size="sm"
        disabled={pending}
        data-testid="settle-fines"
        onClick={() =>
          startTransition(async () => {
            const r = await settleFines(borrowerId, receipt);
            setError(r.error);
            if (!r.error) done('Settled', r.amountPaisa);
          })
        }
      >
        Settle
      </Button>
      <Input aria-label={`Waiver reason for ${name}`} placeholder="Reason to waive" className="h-8 w-48 text-xs" value={reason} onChange={(e) => setReason(e.target.value)} />
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="waive-fines"
        onClick={() =>
          startTransition(async () => {
            const r = await waiveFines(borrowerId, reason);
            setError(r.error);
            if (!r.error) done('Waived', r.amountPaisa);
          })
        }
      >
        Waive
      </Button>
      {error && (
        <span role="alert" className="text-xs text-destructive" data-testid="fine-error">
          {error}
        </span>
      )}
    </div>
  );
}
