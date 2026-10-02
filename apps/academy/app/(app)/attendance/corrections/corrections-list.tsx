'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { approveAttendanceCorrection, rejectAttendanceCorrection } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';

export type CorrectionRow = {
  id: string;
  studentName: string;
  grNumber: string;
  attendanceDate: string;
  oldStatus: string | null;
  newStatus: string;
  reason: string;
  status: string;
};

function DecisionControls({ correctionId }: { correctionId: string }) {
  const [pending, startTransition] = useTransition();
  const [note, setNote] = useState('');

  const onDecide = (action: 'approve' | 'reject') => {
    if (note.trim().length < 10) {
      toast.error('Explain the decision in at least 10 characters.');
      return;
    }
    const fd = new FormData();
    fd.set('correctionId', correctionId);
    fd.set('note', note);
    startTransition(async () => {
      const result = action === 'approve' ? await approveAttendanceCorrection({ error: null }, fd) : await rejectAttendanceCorrection({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(action === 'approve' ? 'Correction approved.' : 'Correction rejected.');
        setNote('');
      }
    });
  };

  return (
    <div className="flex flex-wrap items-center gap-2">
      <Input
        placeholder="Decision note (min 10 chars)"
        className="h-8 w-64"
        value={note}
        onChange={(e) => setNote(e.target.value)}
        data-testid={`correction-decision-note-${correctionId}`}
      />
      <Button type="button" size="sm" disabled={pending} onClick={() => onDecide('approve')} data-testid={`correction-approve-${correctionId}`}>
        Approve
      </Button>
      <Button
        type="button"
        size="sm"
        variant="outline"
        disabled={pending}
        onClick={() => onDecide('reject')}
        data-testid={`correction-reject-${correctionId}`}
      >
        Reject
      </Button>
    </div>
  );
}

export function CorrectionsList({ corrections }: { corrections: CorrectionRow[] }) {
  const pending = corrections.filter((c) => c.status === 'pending');
  const decided = corrections.filter((c) => c.status !== 'pending');

  return (
    <div className="space-y-6">
      <div className="space-y-2">
        <h2 className="text-lg font-medium">Pending</h2>
        {pending.length === 0 ? (
          <p className="text-sm text-muted-foreground">No pending correction requests.</p>
        ) : (
          pending.map((c) => (
            <Card key={c.id} data-testid={`correction-row-${c.id}`}>
              <CardContent className="space-y-2 p-4 text-sm">
                <p className="font-medium">
                  {c.studentName} <span className="text-muted-foreground">({c.grNumber})</span> · {c.attendanceDate}
                </p>
                <p className="text-muted-foreground">
                  {c.oldStatus ?? 'unmarked'} → {c.newStatus}
                </p>
                <p>{c.reason}</p>
                <DecisionControls correctionId={c.id} />
              </CardContent>
            </Card>
          ))
        )}
      </div>

      {decided.length > 0 && (
        <div className="space-y-2">
          <h2 className="text-lg font-medium">Decided</h2>
          {decided.map((c) => (
            <Card key={c.id} data-testid={`correction-row-${c.id}`}>
              <CardContent className="flex items-center justify-between p-4 text-sm">
                <p>
                  {c.studentName} ({c.grNumber}) · {c.attendanceDate} · {c.oldStatus ?? 'unmarked'} → {c.newStatus}
                </p>
                <span data-testid={`correction-status-${c.id}`} className="text-xs font-medium capitalize">
                  {c.status}
                </span>
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
