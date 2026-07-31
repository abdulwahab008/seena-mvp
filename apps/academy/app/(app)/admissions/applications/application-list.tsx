'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import {
  issueOffer,
  respondToOffer,
  joinWaitlist,
  removeFromWaitlist,
  checkChecklistCompleteness,
  setDocumentSubmission,
  type MissingItem,
} from './actions';
import { OFFER_DECLINE_REASONS, DOC_STATUSES } from '@/lib/validation';
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
  waitlist: { id: string; position: number | null; status: string } | null;
  checklistSnapshot: { doc_type: string; is_mandatory: boolean; min_count: number }[];
};

function ChecklistPanel({ applicationId, docTypes }: { applicationId: string; docTypes: string[] }) {
  const [pending, startTransition] = useTransition();
  const [result, setResult] = useState<{ complete: boolean; missing: MissingItem[] } | null>(null);
  const [docType, setDocType] = useState(docTypes[0] ?? '');
  const [status, setStatus] = useState('uploaded');
  const [count, setCount] = useState('');
  const [deadline, setDeadline] = useState('');

  const onCheck = () => {
    startTransition(async () => {
      const r = await checkChecklistCompleteness(applicationId);
      if (r.error) toast.error(r.error);
      else setResult({ complete: r.complete!, missing: r.missing! });
    });
  };

  const onSave = () => {
    const fd = new FormData();
    fd.set('applicationId', applicationId);
    fd.set('docType', docType);
    fd.set('status', status);
    if (count) fd.set('uploadedCount', count);
    if (deadline) fd.set('promisedDeadline', deadline);
    startTransition(async () => {
      const r = await setDocumentSubmission({ error: null }, fd);
      if (r.error) toast.error(r.error);
      else {
        toast.success('Document status saved.');
        onCheck();
      }
    });
  };

  if (docTypes.length === 0) return null;

  return (
    <div className="mt-2 space-y-2 border-t pt-2" data-testid={`checklist-panel-${applicationId}`}>
      <div className="flex items-center gap-2">
        <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onCheck}>
          Check checklist
        </Button>
        {result && (
          <span className="text-xs" data-testid={`checklist-result-${applicationId}`}>
            {result.complete
              ? 'Complete'
              : `Incomplete — missing: ${result.missing.map((m) => `${m.doc_type.replace(/_/g, ' ')} (${m.missing})`).join(', ')}`}
          </span>
        )}
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <Select value={docType} onValueChange={setDocType}>
          <SelectTrigger className="h-8 w-40" data-testid={`checklist-doctype-trigger-${applicationId}`}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {docTypes.map((d) => (
              <SelectItem key={d} value={d}>
                {d.replace(/_/g, ' ')}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={status} onValueChange={setStatus}>
          <SelectTrigger className="h-8 w-32" data-testid={`checklist-status-trigger-${applicationId}`}>
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {DOC_STATUSES.map((s) => (
              <SelectItem key={s} value={s}>
                {s}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        {status === 'uploaded' && (
          <Input placeholder="Count" type="number" className="h-8 w-20" value={count} onChange={(e) => setCount(e.target.value)} />
        )}
        {status === 'promised' && (
          <Input type="date" className="h-8 w-40" value={deadline} onChange={(e) => setDeadline(e.target.value)} />
        )}
        <Button type="button" size="sm" disabled={pending} onClick={onSave}>
          Save
        </Button>
      </div>
    </div>
  );
}

function JoinWaitlistButton({ applicationId }: { applicationId: string }) {
  const [pending, startTransition] = useTransition();

  const onClick = () => {
    startTransition(async () => {
      const result = await joinWaitlist(applicationId);
      if (result.error) toast.error(result.error);
      else toast.success('Added to the waitlist.');
    });
  };

  return (
    <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onClick}>
      {pending ? 'Adding…' : 'Join waitlist'}
    </Button>
  );
}

function WaitlistBadge({ waitlist }: { waitlist: { id: string; position: number | null; status: string } }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');

  const onRemove = () => {
    if (!reason.trim()) {
      toast.error('Enter a reason for removing this applicant.');
      return;
    }
    startTransition(async () => {
      const result = await removeFromWaitlist(waitlist.id, reason);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Removed from the waitlist.');
        setReason('');
      }
    });
  };

  if (waitlist.status === 'offer_pending') {
    return (
      <span className="text-xs text-muted-foreground" data-testid={`waitlist-status-${waitlist.id}`}>
        Promoted — ready for an offer
      </span>
    );
  }

  return (
    <div className="flex items-center gap-2" data-testid={`waitlist-status-${waitlist.id}`}>
      <span className="text-xs text-muted-foreground">Waitlist position {waitlist.position}</span>
      <Input
        placeholder="Removal reason"
        className="h-8 w-40"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
      />
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onRemove}>
        Remove
      </Button>
    </div>
  );
}

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
          <CardContent className="p-4">
            <div className="flex items-center justify-between gap-4">
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
              ) : a.waitlist ? (
                <WaitlistBadge waitlist={a.waitlist} />
              ) : (
                !a.offer &&
                a.availableSeats !== null && (
                  <div className="flex items-center gap-3">
                    <span className="text-xs text-muted-foreground" data-testid={`available-seats-${a.applicationNo}`}>
                      {a.availableSeats} seat(s) left
                    </span>
                    {a.availableSeats > 0 ? (
                      <IssueOfferForm applicationId={a.id} availableSeats={a.availableSeats} />
                    ) : (
                      <JoinWaitlistButton applicationId={a.id} />
                    )}
                  </div>
                )
              )}
            </div>
            <ChecklistPanel applicationId={a.id} docTypes={a.checklistSnapshot.map((d) => d.doc_type)} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
