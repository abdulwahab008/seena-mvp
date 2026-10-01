'use client';

import { useRef, useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { formatPkrCompact } from '@/lib/format-money';
import { findBorrowers, issueCopy, type Borrower, type IssueResult } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function IssueDesk() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [query, setQuery] = useState('');
  const [candidates, setCandidates] = useState<Borrower[]>([]);
  const [borrower, setBorrower] = useState<Borrower | null>(null);
  const [lookupError, setLookupError] = useState<string | null>(null);
  const [barcode, setBarcode] = useState('');
  const [result, setResult] = useState<IssueResult | null>(null);
  const barcodeRef = useRef<HTMLInputElement>(null);

  const pick = (b: Borrower) => {
    setBorrower(b);
    setCandidates([]);
    setResult(null);
    setTimeout(() => barcodeRef.current?.focus(), 0);
  };

  const lookup = () =>
    startTransition(async () => {
      setResult(null);
      const r = await findBorrowers(query);
      setLookupError(r.error ?? (r.borrowers.length === 0 ? 'No borrower found.' : null));
      if (r.borrowers.length === 1) pick(r.borrowers[0]!);
      else {
        setBorrower(null);
        setCandidates(r.borrowers);
      }
    });

  const issue = () =>
    startTransition(async () => {
      const r = await issueCopy(barcode, borrower!.id);
      setResult(r);
      if (!r.error) {
        setBarcode('');
        router.refresh();
        // keep the borrower selected for the next scan; refresh their counts
        const again = await findBorrowers(borrower!.name);
        const fresh = again.borrowers.find((b) => b.id === borrower!.id);
        if (fresh) setBorrower(fresh);
      }
      barcodeRef.current?.focus();
    });

  return (
    <div className="space-y-4" data-testid="issue-desk">
      <div className="flex flex-wrap items-end gap-3">
        <div className="space-y-1">
          <Label htmlFor="borrower-query">Borrower card (GR number) or name</Label>
          <Input
            id="borrower-query"
            className="w-72"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                e.preventDefault();
                lookup();
              }
            }}
          />
        </div>
        <Button type="button" variant="outline" disabled={pending} onClick={lookup} data-testid="find-borrower">
          Find borrower
        </Button>
      </div>
      {lookupError && <p className="text-sm text-muted-foreground">{lookupError}</p>}
      {candidates.length > 0 && (
        <ul className="space-y-1 text-sm" data-testid="borrower-candidates">
          {candidates.map((c) => (
            <li key={c.id}>
              <button type="button" className="underline" onClick={() => pick(c)}>
                {c.name}
              </button>{' '}
              <span className="text-muted-foreground">{c.detail}</span>
            </li>
          ))}
        </ul>
      )}

      {borrower && (
        <div className="space-y-3 rounded-md border p-3">
          <p className="text-sm" data-testid="selected-borrower">
            <span className="font-medium">{borrower.name}</span> <span className="text-muted-foreground">{borrower.detail}</span> · {borrower.openLoans} on loan
            {borrower.outstandingPaisa > 0 && <span className="ml-2 text-destructive">Unpaid fines {formatPkrCompact(borrower.outstandingPaisa)}</span>}
          </p>
          <form
            className="flex flex-wrap items-end gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              issue();
            }}
          >
            <div className="space-y-1">
              <Label htmlFor="issue-barcode">Book barcode</Label>
              <Input id="issue-barcode" ref={barcodeRef} className="w-64 font-mono" value={barcode} onChange={(e) => setBarcode(e.target.value)} autoComplete="off" />
            </div>
            <Button type="submit" disabled={pending} data-testid="issue-copy">
              Issue
            </Button>
          </form>
        </div>
      )}

      {result?.error && (
        <p role="alert" className="text-sm text-destructive" data-testid="issue-error">
          {result.error}
        </p>
      )}
      {result?.loan && (
        <p className="text-sm text-green-700 dark:text-green-400" data-testid="issue-ok">
          Issued {result.loan.title} ({result.loan.accessionNo}) to {result.loan.borrower}, due {result.loan.dueOn}. {result.loan.openLoans} of {result.loan.maxLoans} loans in use.
        </p>
      )}
    </div>
  );
}
