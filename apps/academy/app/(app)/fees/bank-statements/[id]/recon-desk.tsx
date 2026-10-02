'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { resolveBankExceptionSchema, type ResolveBankExceptionInput } from '@/lib/validation';
import { closeImport, reconcileImport, resolveException } from './actions';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';

export type ExceptionRow = {
  id: string;
  reason: string;
  expected: number | null;
  received: number;
  resolved: boolean;
  note: string | null;
  bankRef: string | null;
  challanRef: string | null;
  date: string | null;
};

const pkr = (paisa: number | null) => (paisa === null ? '—' : `PKR ${(paisa / 100).toLocaleString('en-PK', { minimumFractionDigits: 2 })}`);

function ExceptionCard({ importId, row }: { importId: string; row: ExceptionRow }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<ResolveBankExceptionInput>({
    resolver: zodResolver(resolveBankExceptionSchema),
    defaultValues: { exceptionId: row.id, action: 'post', note: '', challanNo: '' },
  });

  const submit = (action: 'post' | 'dismiss') =>
    form.handleSubmit((values) => {
      setError(null);
      startTransition(async () => {
        const result = await resolveException(importId, { ...values, action });
        if (result.error) setError(result.error);
        else {
          toast.success(action === 'post' ? 'Payment posted.' : 'Line dismissed.');
          router.refresh();
        }
      });
    })();

  return (
    <Card data-testid="exception-card">
      <CardContent className="space-y-3 p-4 text-sm">
        <div className="flex items-start justify-between gap-2">
          <div>
            <div className="font-medium">
              {row.bankRef ?? '—'} · challan {row.challanRef ?? '—'} · {row.date ?? '—'}
            </div>
            <div className="text-muted-foreground">
              received {pkr(row.received)}
              {row.expected !== null ? ` · expected ${pkr(row.expected)}` : ''}
            </div>
          </div>
          <Badge variant={row.resolved ? 'outline' : 'warning'}>{row.reason.replace('_', ' ')}</Badge>
        </div>
        {row.resolved ? (
          <p className="text-muted-foreground">Resolved — {row.note}</p>
        ) : (
          <div className="space-y-2">
            <Input placeholder="Note (required)" {...form.register('note')} />
            {(row.reason === 'unmatched' || row.reason === 'check_digit_fail' || row.reason === 'possible_duplicate') && (
              <Input placeholder="Challan number to post against (12 digits, optional)" inputMode="numeric" {...form.register('challanNo')} />
            )}
            {(form.formState.errors.note || form.formState.errors.challanNo) && (
              <p className="text-destructive">{form.formState.errors.note?.message ?? form.formState.errors.challanNo?.message}</p>
            )}
            <div className="flex gap-2">
              {row.reason !== 'cancelled_challan' && (
                <Button type="button" size="sm" disabled={pending} onClick={() => submit('post')} data-testid="exception-post">
                  {row.reason === 'amount_mismatch' ? 'Post as partial payment' : 'Post payment'}
                </Button>
              )}
              <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => submit('dismiss')} data-testid="exception-dismiss">
                Dismiss
              </Button>
            </div>
            {error && (
              <p role="alert" className="text-destructive">
                {error}
              </p>
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

export function ReconDesk({ importId, status, unresolved, exceptions }: { importId: string; status: string; unresolved: number; exceptions: ExceptionRow[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);

  const run = (fn: () => Promise<{ error: string | null }>, ok: string) =>
    startTransition(async () => {
      setError(null);
      const result = await fn();
      if (result.error) setError(result.error);
      else {
        toast.success(ok);
        router.refresh();
      }
    });

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        {(status === 'parsed' || status === 'reconciled') && (
          <Button type="button" disabled={pending} onClick={() => run(() => reconcileImport(importId), 'Reconciliation run.')} data-testid="reconcile-run">
            {status === 'parsed' ? 'Run reconciliation' : 'Run again'}
          </Button>
        )}
        {status === 'reconciled' && (
          <Button type="button" variant="outline" disabled={pending || unresolved > 0} onClick={() => run(() => closeImport(importId), 'Import closed.')} data-testid="close-import">
            Close import {unresolved > 0 ? `(${unresolved} unresolved)` : ''}
          </Button>
        )}
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="space-y-2">
        {exceptions.length === 0 ? <p className="text-sm text-muted-foreground">No exceptions.</p> : exceptions.map((e) => <ExceptionCard key={e.id} importId={importId} row={e} />)}
      </div>
    </div>
  );
}
