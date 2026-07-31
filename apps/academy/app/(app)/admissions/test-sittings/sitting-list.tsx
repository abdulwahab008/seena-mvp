'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { allocateTestSeat, fetchRollSlip, type RollSlipPayload } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type SittingRow = {
  id: string;
  startsAt: string;
  venue: string | null;
  capacity: number;
  classLevelId: string;
  className: string;
  activeCount: number;
};

export type EligibleApplication = { id: string; applicationNo: string | null; childName: string; classAppliedId: string };

function AllocateSeatForm({ sittingId, applications }: { sittingId: string; applications: EligibleApplication[] }) {
  const [pending, startTransition] = useTransition();
  const [applicationId, setApplicationId] = useState('');

  const onAllocate = () => {
    if (!applicationId) {
      toast.error('Choose an application.');
      return;
    }
    const fd = new FormData();
    fd.set('sittingId', sittingId);
    fd.set('applicationId', applicationId);
    startTransition(async () => {
      const result = await allocateTestSeat({ error: null, seatNo: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`Allocated seat ${result.seatNo}.`);
        setApplicationId('');
      }
    });
  };

  if (applications.length === 0) return <p className="text-xs text-muted-foreground">No eligible applications for this class.</p>;

  return (
    <div className="flex items-center gap-2">
      <Select value={applicationId} onValueChange={setApplicationId}>
        <SelectTrigger className="h-8 w-56" data-testid={`allocate-app-trigger-${sittingId}`}>
          <SelectValue placeholder="Choose an application" />
        </SelectTrigger>
        <SelectContent>
          {applications.map((a) => (
            <SelectItem key={a.id} value={a.id}>
              {a.childName} ({a.applicationNo})
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button type="button" size="sm" disabled={pending} onClick={onAllocate}>
        {pending ? 'Allocating…' : 'Allocate seat'}
      </Button>
    </div>
  );
}

function RollSlipViewer({ sittingId }: { sittingId: string }) {
  const [pending, startTransition] = useTransition();
  const [payload, setPayload] = useState<RollSlipPayload | null>(null);

  const onView = () => {
    startTransition(async () => {
      const result = await fetchRollSlip(sittingId);
      if (result.error) toast.error(result.error);
      else setPayload(result.payload);
    });
  };

  return (
    <div className="mt-2 space-y-2 border-t pt-2">
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onView}>
        View roll slip
      </Button>
      {payload && (
        <ul className="text-xs text-muted-foreground" data-testid={`roll-slip-${sittingId}`}>
          {payload.candidates.map((c) => (
            <li key={c.seat_no}>
              Seat {c.seat_no} — {c.child_name} ({c.application_no})
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

export function SittingList({ sittings, applications }: { sittings: SittingRow[]; applications: EligibleApplication[] }) {
  if (sittings.length === 0) {
    return <p className="text-sm text-muted-foreground">No test sittings scheduled yet.</p>;
  }

  return (
    <div className="space-y-2">
      {sittings.map((s) => (
        <Card key={s.id} data-testid={`sitting-row-${s.id}`}>
          <CardContent className="p-4">
            <div className="flex items-center justify-between">
              <div>
                <p className="font-medium">
                  {s.className} · {new Date(s.startsAt).toLocaleString()}
                </p>
                <p className="text-sm text-muted-foreground">
                  {s.venue ?? 'No venue set'} · <span data-testid={`sitting-seats-${s.id}`}>{s.activeCount}</span>/{s.capacity} seats filled
                </p>
              </div>
              <AllocateSeatForm sittingId={s.id} applications={applications.filter((a) => a.classAppliedId === s.classLevelId)} />
            </div>
            <RollSlipViewer sittingId={s.id} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
