'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { toast } from 'sonner';
import { cancelReservation, renewLoan, reserveTitle, searchTitles } from './actions';
import { findBorrowers, type Borrower } from '../circulation/actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function ReserveForBorrower() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [titleQuery, setTitleQuery] = useState('');
  const [titles, setTitles] = useState<{ id: string; title: string; titleUr: string | null }[]>([]);
  const [title, setTitle] = useState<{ id: string; title: string } | null>(null);
  const [borrowerQuery, setBorrowerQuery] = useState('');
  const [borrowers, setBorrowers] = useState<Borrower[]>([]);
  const [borrower, setBorrower] = useState<Borrower | null>(null);
  const [message, setMessage] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null);

  return (
    <div className="space-y-4" data-testid="reserve-for-borrower">
      <div className="grid gap-4 md:grid-cols-2">
        <div className="space-y-2">
          <Label htmlFor="res-title-q">Title</Label>
          <div className="flex gap-2">
            <Input id="res-title-q" value={titleQuery} onChange={(e) => setTitleQuery(e.target.value)} dir="auto" />
            <Button type="button" variant="outline" disabled={pending} onClick={() => startTransition(async () => setTitles(await searchTitles(titleQuery)))}>
              Search
            </Button>
          </div>
          {title ? (
            <p className="text-sm" data-testid="chosen-title">
              Chosen: <span className="font-medium">{title.title}</span>
            </p>
          ) : (
            <ul className="space-y-1 text-sm">
              {titles.map((t) => (
                <li key={t.id}>
                  <button type="button" className="underline" onClick={() => setTitle(t)}>
                    {t.title}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        <div className="space-y-2">
          <Label htmlFor="res-borrower-q">Borrower (GR number or name)</Label>
          <div className="flex gap-2">
            <Input id="res-borrower-q" value={borrowerQuery} onChange={(e) => setBorrowerQuery(e.target.value)} />
            <Button
              type="button"
              variant="outline"
              disabled={pending}
              onClick={() =>
                startTransition(async () => {
                  const r = await findBorrowers(borrowerQuery);
                  if (r.borrowers.length === 1) {
                    setBorrower(r.borrowers[0]!);
                    setBorrowers([]);
                  } else setBorrowers(r.borrowers);
                })
              }
            >
              Find
            </Button>
          </div>
          {borrower ? (
            <p className="text-sm" data-testid="chosen-borrower">
              Chosen: <span className="font-medium">{borrower.name}</span> <span className="text-muted-foreground">{borrower.detail}</span>
            </p>
          ) : (
            <ul className="space-y-1 text-sm">
              {borrowers.map((b) => (
                <li key={b.id}>
                  <button type="button" className="underline" onClick={() => setBorrower(b)}>
                    {b.name}
                  </button>{' '}
                  <span className="text-muted-foreground">{b.detail}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
      <Button
        type="button"
        disabled={pending || !title || !borrower}
        data-testid="reserve-submit"
        onClick={() =>
          startTransition(async () => {
            const r = await reserveTitle(title!.id, borrower!.id);
            if (r.error) setMessage({ kind: 'error', text: r.error });
            else {
              setMessage({ kind: 'ok', text: `Reserved. Queue position ${r.position}.` });
              toast.success('Reservation saved.');
              router.refresh();
            }
          })
        }
      >
        Reserve
      </Button>
      {message && (
        <p role={message.kind === 'error' ? 'alert' : 'status'} className={message.kind === 'error' ? 'text-sm text-destructive' : 'text-sm'} data-testid="reserve-message">
          {message.text}
        </p>
      )}
    </div>
  );
}

export function CancelReservationButton({ reservationId }: { reservationId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="flex items-center gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="cancel-reservation"
        onClick={() =>
          startTransition(async () => {
            const r = await cancelReservation(reservationId);
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Cancel
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}

// Self-service from the catalogue: a student, teacher or parent reserves a title whose copies are all out.
export function ReserveSelfButton({ titleId }: { titleId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [message, setMessage] = useState<string | null>(null);
  return (
    <span className="flex items-center gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="reserve-self"
        onClick={() =>
          startTransition(async () => {
            const r = await reserveTitle(titleId);
            setMessage(r.error ?? `Reserved: you are number ${r.position} in the queue.`);
            if (!r.error) router.refresh();
          })
        }
      >
        Reserve
      </Button>
      {message && <span className="text-xs" data-testid="reserve-self-message">{message}</span>}
    </span>
  );
}

export function RenewButton({ loanId }: { loanId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="flex items-center gap-2">
      <Button
        size="sm"
        variant="outline"
        disabled={pending}
        data-testid="renew-loan"
        onClick={() =>
          startTransition(async () => {
            const r = await renewLoan(loanId);
            setError(r.error);
            if (!r.error) router.refresh();
          })
        }
      >
        Renew
      </Button>
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
