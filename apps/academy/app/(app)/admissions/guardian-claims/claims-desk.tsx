'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { Textarea } from '@/components/ui/textarea';
import { resolveGuardianClaim } from './actions';

export type ClaimRow = {
  id: string;
  status: string;
  reason: string | null;
  note: string | null;
  createdAt: string;
  studentName: string;
  grNumber: string | null;
  guardianName: string;
  hasPhone: boolean;
};
export type AttemptRow = { id: string; gr: string | null; outcome: string; at: string };

const noteSchema = z.object({ note: z.string().trim().max(500).optional() });
type NoteInput = z.infer<typeof noteSchema>;

function ClaimCard({ claim }: { claim: ClaimRow }) {
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const [invitePath, setInvitePath] = useState<string | null>(null);
  const form = useForm<NoteInput>({ resolver: zodResolver(noteSchema) });

  const resolve = (approve: boolean) =>
    form.handleSubmit((values) => {
      setError(null);
      startTransition(async () => {
        const result = await resolveGuardianClaim({ claimId: claim.id, approve, note: values.note });
        if (result.error !== null) setError(result.error);
        else setInvitePath(result.inviteUrlPath);
      });
    })();

  return (
    <Card data-testid="claim-card">
      <CardHeader className="flex flex-row items-start justify-between gap-2 space-y-0 p-4">
        <div>
          <CardTitle className="text-base">
            {claim.guardianName} for {claim.studentName}
          </CardTitle>
          <p className="text-xs text-muted-foreground">
            GR {claim.grNumber ?? '—'} · {new Date(claim.createdAt).toLocaleString()}
            {claim.reason ? ` · ${claim.reason === 'NO_PHONE' ? 'no phone on record' : 'could not receive the code'}` : ''}
          </p>
        </div>
        <Badge variant={claim.status === 'manual_review' ? 'warning' : 'outline'}>{claim.status.replace('_', ' ')}</Badge>
      </CardHeader>
      {claim.status === 'manual_review' && (
        <CardContent className="space-y-3 p-4 pt-0">
          {!claim.hasPhone && <p className="text-sm text-amber-700">This guardian has no phone on record. Add one before approving.</p>}
          <Textarea placeholder="How you verified this parent (optional)" {...form.register('note')} />
          <div className="flex gap-2">
            <Button type="button" size="sm" disabled={pending || !claim.hasPhone} onClick={() => resolve(true)} data-testid="claim-approve">
              Approve and create invite
            </Button>
            <Button type="button" size="sm" variant="outline" disabled={pending} onClick={() => resolve(false)} data-testid="claim-reject">
              Reject
            </Button>
          </div>
          {error && (
            <p role="alert" className="text-sm text-destructive">
              {error}
            </p>
          )}
        </CardContent>
      )}
      {invitePath && (
        <CardContent className="p-4 pt-0">
          <p className="text-sm">Send this link to the parent (valid 72 hours):</p>
          <code className="block break-all rounded bg-muted p-2 text-xs" data-testid="claim-invite-link">
            {`${typeof window === 'undefined' ? '' : window.location.origin}${invitePath}`}
          </code>
        </CardContent>
      )}
    </Card>
  );
}

export function ClaimsDesk({ claims, attempts }: { claims: ClaimRow[]; attempts: AttemptRow[] }) {
  const queue = claims.filter((c) => c.status === 'manual_review');
  const rest = claims.filter((c) => c.status !== 'manual_review');
  return (
    <div className="space-y-6">
      <section className="space-y-3">
        <h2 className="text-lg font-medium">Awaiting verification ({queue.length})</h2>
        {queue.length === 0 ? (
          <EmptyState title="Nothing waiting" description="Claims that need the office appear here." />
        ) : (
          queue.map((c) => <ClaimCard key={c.id} claim={c} />)
        )}
      </section>
      {rest.length > 0 && (
        <section className="space-y-3">
          <h2 className="text-lg font-medium">Recent claims</h2>
          {rest.map((c) => (
            <ClaimCard key={c.id} claim={c} />
          ))}
        </section>
      )}
      <section className="space-y-2">
        <h2 className="text-lg font-medium">Failed and locked attempts, last 24 hours ({attempts.length})</h2>
        {attempts.length === 0 ? (
          <p className="text-sm text-muted-foreground">No failed claim attempts.</p>
        ) : (
          <ul className="divide-y rounded-md border text-sm" data-testid="claim-attempts">
            {attempts.map((a) => (
              <li key={a.id} className="flex justify-between px-3 py-2">
                <span>GR {a.gr ?? '—'}</span>
                <span className="text-muted-foreground">
                  {a.outcome} · {new Date(a.at).toLocaleTimeString()}
                </span>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
