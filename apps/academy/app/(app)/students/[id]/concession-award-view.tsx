'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { requestConcessionAward, decideConcessionAward } from '../actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

type Scheme = { id: string; code: string; name_en: string; calc_type: string };

export type AwardRow = {
  id: string;
  schemeName: string;
  calcType: string;
  value: number;
  effectiveFrom: string;
  effectiveTo: string;
  status: string;
  rejectionReason: string | null;
  canApprove: boolean;
};

function RequestAwardForm({ studentId, enrolmentId, schemes }: { studentId: string; enrolmentId: string; schemes: Scheme[] }) {
  const [pending, startTransition] = useTransition();
  const [schemeId, setSchemeId] = useState('');
  const [value, setValue] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [documentPath, setDocumentPath] = useState('');

  const onSubmit = () => {
    if (!schemeId || !value || !from || !to) {
      toast.error('Fill in scheme, value and both dates.');
      return;
    }
    const fd = new FormData();
    fd.set('schemeId', schemeId);
    fd.set('value', value);
    fd.set('effectiveFrom', from);
    fd.set('effectiveTo', to);
    if (documentPath) fd.set('documentPath', documentPath);
    startTransition(async () => {
      const result = await requestConcessionAward(studentId, enrolmentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Concession award requested.');
        setSchemeId('');
        setValue('');
        setFrom('');
        setTo('');
        setDocumentPath('');
      }
    });
  };

  if (schemes.length === 0) {
    return <p className="text-sm text-muted-foreground">No active concession schemes configured.</p>;
  }

  return (
    <div className="grid grid-cols-2 gap-2 rounded-lg border p-3 md:grid-cols-5">
      <div className="space-y-1">
        <Label>Scheme</Label>
        <Select value={schemeId} onValueChange={setSchemeId}>
          <SelectTrigger data-testid="award-scheme-trigger">
            <SelectValue placeholder="Select a scheme" />
          </SelectTrigger>
          <SelectContent>
            {schemes.map((s) => (
              <SelectItem key={s.id} value={s.id}>
                {s.name_en}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="award-value">Value</Label>
        <Input id="award-value" type="number" value={value} onChange={(e) => setValue(e.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="award-from">From</Label>
        <Input id="award-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="award-to">To</Label>
        <Input id="award-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="award-doc">Document (optional)</Label>
        <Input id="award-doc" placeholder="hardship-letter.pdf" value={documentPath} onChange={(e) => setDocumentPath(e.target.value)} />
      </div>
      <Button type="button" disabled={pending} onClick={onSubmit} className="col-span-2 w-fit md:col-span-1">
        {pending ? 'Requesting…' : 'Request'}
      </Button>
    </div>
  );
}

function DecideAwardControls({ studentId, awardId }: { studentId: string; awardId: string }) {
  const [pending, startTransition] = useTransition();
  const [reason, setReason] = useState('');
  const [showReject, setShowReject] = useState(false);

  const approve = () => {
    startTransition(async () => {
      const result = await decideConcessionAward(studentId, awardId, true);
      if (result.error) toast.error(result.error);
      else toast.success('Award approved.');
    });
  };

  const reject = () => {
    if (reason.trim().length < 10) {
      toast.error('Rejection reason must be at least 10 characters.');
      return;
    }
    startTransition(async () => {
      const result = await decideConcessionAward(studentId, awardId, false, reason);
      if (result.error) toast.error(result.error);
      else toast.success('Award rejected.');
    });
  };

  if (!showReject) {
    return (
      <div className="flex items-center gap-2">
        <Button type="button" size="sm" disabled={pending} onClick={approve}>
          Approve
        </Button>
        <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={() => setShowReject(true)}>
          Reject
        </Button>
      </div>
    );
  }

  return (
    <div className="flex items-center gap-1">
      <Input placeholder="Reason (10+ chars)" className="h-9 w-48" value={reason} onChange={(e) => setReason(e.target.value)} />
      <Button type="button" size="sm" variant="destructive" disabled={pending} onClick={reject}>
        Confirm reject
      </Button>
    </div>
  );
}

export function ConcessionAwardView({
  studentId,
  enrolmentId,
  awards,
  schemes,
  canRequest,
}: {
  studentId: string;
  enrolmentId: string;
  awards: AwardRow[];
  schemes: Scheme[];
  canRequest: boolean;
}) {
  return (
    <div className="space-y-2">
      {awards.length === 0 ? (
        <p className="text-sm text-muted-foreground">No concession awards yet.</p>
      ) : (
        awards.map((a) => (
          <Card key={a.id} data-testid={`award-row-${a.id}`}>
            <CardContent className="flex items-center justify-between gap-3 p-3 text-sm">
              <div>
                <p className="font-medium">
                  {a.schemeName} — {a.calcType === 'percentage' ? `${a.value}%` : `PKR ${a.value.toLocaleString()}`}{' '}
                  <span className="text-muted-foreground" data-testid={`award-status-${a.id}`}>
                    ({a.status})
                  </span>
                </p>
                <p className="text-xs text-muted-foreground">
                  {a.effectiveFrom} to {a.effectiveTo}
                  {a.status === 'rejected' && a.rejectionReason ? ` · ${a.rejectionReason}` : ''}
                </p>
              </div>
              {a.status === 'pending' && a.canApprove && <DecideAwardControls studentId={studentId} awardId={a.id} />}
            </CardContent>
          </Card>
        ))
      )}
      {canRequest && <RequestAwardForm studentId={studentId} enrolmentId={enrolmentId} schemes={schemes} />}
    </div>
  );
}
