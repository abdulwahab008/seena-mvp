'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { issueOffer, respondToOffer } from './actions';
import { OFFER_DECLINE_REASONS } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type ApplicationRow = {
  id: string;
  applicationNo: string | null;
  status: string;
  childName: string;
  className: string;
  offer: { id: string; status: string; expires_at: string } | null;
  availableSeats: number | null;
};

function IssueOfferForm({ applicationId, availableSeats }: { applicationId: string; availableSeats: number }) {
  const [pending, startTransition] = useTransition();
  const [fee, setFee] = useState('');

  const onClick = () => {
    const amount = Number(fee);
    if (!fee || !(amount > 0)) {
      toast.error('Enter a fee amount.');
      return;
    }
    const fd = new FormData();
    fd.set('feeAmount', fee);
    startTransition(async () => {
      const result = await issueOffer(applicationId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Offer issued.');
        setFee('');
      }
    });
  };

  return (
    <div className="flex items-end gap-2">
      <div className="space-y-1">
        <Label htmlFor={`fee-${applicationId}`}>Admission fee</Label>
        <Input
          id={`fee-${applicationId}`}
          type="number"
          step="0.01"
          placeholder="5000"
          className="w-28"
          value={fee}
          onChange={(e) => setFee(e.target.value)}
        />
      </div>
      <Button type="button" size="sm" disabled={pending || availableSeats <= 0} onClick={onClick}>
        {availableSeats <= 0 ? 'No seats' : pending ? 'Issuing…' : 'Issue offer'}
      </Button>
    </div>
  );
}

function AcceptButton({ offerId }: { offerId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('response', 'accepted');
    startTransition(async () => {
      const result = await respondToOffer({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Offer accepted.');
    });
  };

  return (
    <Button type="button" size="sm" disabled={pending} onClick={onClick}>
      Accept
    </Button>
  );
}

function DeclineControl({ offerId }: { offerId: string }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');

  const onClick = () => {
    if (!reason) {
      toast.error('Choose a decline reason.');
      return;
    }
    const fd = new FormData();
    fd.set('offerId', offerId);
    fd.set('response', 'declined');
    fd.set('declineReason', reason);
    startTransition(async () => {
      const result = await respondToOffer({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Offer declined.');
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Select value={reason} onValueChange={setReason}>
        <SelectTrigger className="h-9 w-40" data-testid={`decline-reason-trigger-${offerId}`}>
          <SelectValue placeholder="Reason" />
        </SelectTrigger>
        <SelectContent>
          {OFFER_DECLINE_REASONS.map((r) => (
            <SelectItem key={r} value={r}>
              {r.replace(/_/g, ' ')}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={onClick}>
        Decline
      </Button>
    </div>
  );
}

export function ApplicationList({ applications }: { applications: ApplicationRow[] }) {
  if (applications.length === 0) {
    return <p className="text-sm text-muted-foreground">No applications yet.</p>;
  }

  return (
    <div className="space-y-2">
      {applications.map((a) => (
        <Card key={a.id} data-testid={`application-row-${a.applicationNo}`}>
          <CardContent className="flex items-center justify-between gap-4 p-4">
            <div>
              <p className="font-medium">
                {a.childName} <span className="text-muted-foreground">({a.applicationNo})</span>
              </p>
              <p className="text-sm text-muted-foreground">
                {a.className} · <span data-testid={`application-status-${a.applicationNo}`}>{a.status}</span>
                {a.offer && a.offer.status === 'issued' && ` · offer expires ${new Date(a.offer.expires_at).toLocaleDateString()}`}
              </p>
            </div>
            {a.offer && a.offer.status === 'issued' ? (
              <div className="flex items-center gap-2">
                <AcceptButton offerId={a.offer.id} />
                <DeclineControl offerId={a.offer.id} />
              </div>
            ) : (
              !a.offer &&
              a.availableSeats !== null && (
                <div className="flex items-center gap-3">
                  <span className="text-xs text-muted-foreground" data-testid={`available-seats-${a.applicationNo}`}>
                    {a.availableSeats} seat(s) left
                  </span>
                  <IssueOfferForm applicationId={a.id} availableSeats={a.availableSeats} />
                </div>
              )
            )}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
