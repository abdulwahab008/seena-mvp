'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { decideCertificateRequest } from './actions';

export type PendingRequest = { id: string; student: string; gr: string; purpose: string; justification: string | null; requestedAt: string };

export function RequestQueue({ requests }: { requests: PendingRequest[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [reasons, setReasons] = useState<Record<string, string>>({});
  const [errors, setErrors] = useState<Record<string, string | null>>({});

  const decide = (id: string, decision: 'approve' | 'reject') =>
    startTransition(async () => {
      const r = await decideCertificateRequest({ requestId: id, decision, reason: reasons[id], language: 'en' });
      setErrors({ ...errors, [id]: r.error });
      if (!r.error) {
        toast.success(r.notice ?? 'Done.');
        router.refresh();
      }
    });

  if (requests.length === 0) {
    return (
      <p className="text-sm text-muted-foreground" data-testid="cert-queue-empty">
        No bonafide requests are waiting.
      </p>
    );
  }
  return (
    <div className="space-y-3" data-testid="cert-queue">
      {requests.map((r) => (
        <div key={r.id} className="space-y-2 rounded-md border p-3 text-sm" data-testid="cert-queue-row">
          <p>
            <span className="font-medium">{r.student}</span> ({r.gr}) · {r.purpose}
            <span className="text-muted-foreground"> · requested {new Date(r.requestedAt).toLocaleString('en-PK', { timeZone: 'Asia/Karachi' })}</span>
          </p>
          {r.justification && <p className="text-muted-foreground">“{r.justification}”</p>}
          <div className="flex flex-wrap items-center gap-2">
            <Button size="sm" disabled={pending} onClick={() => decide(r.id, 'approve')} data-testid="cert-approve">
              Approve and issue
            </Button>
            <input
              aria-label="Reason for rejecting"
              placeholder="Reason (required to reject)"
              value={reasons[r.id] ?? ''}
              onChange={(e) => setReasons({ ...reasons, [r.id]: e.target.value })}
              className="h-8 min-w-48 flex-1 rounded-md border bg-background px-2"
            />
            <Button size="sm" variant="outline" disabled={pending} onClick={() => decide(r.id, 'reject')} data-testid="cert-reject">
              Reject
            </Button>
          </div>
          {errors[r.id] && (
            <p role="alert" className="text-destructive" data-testid="cert-queue-error">
              {errors[r.id]}
            </p>
          )}
        </div>
      ))}
    </div>
  );
}
