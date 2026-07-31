'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import {
  allocateTestSeat,
  fetchRollSlip,
  setTestScore,
  setTestAttendance,
  publishMeritList,
  unlockTestScores,
  type RollSlipPayload,
} from './actions';
import { TEST_ATTENDANCES } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type CandidateRow = {
  id: string;
  seatNo: number;
  childName: string;
  attendance: string;
  scores: { subjectCode: string; obtained: number; total: number }[];
  merit: { pct: number; rnk: number; tieBreakBasis: string } | null;
};

export type SittingRow = {
  id: string;
  startsAt: string;
  venue: string | null;
  capacity: number;
  classLevelId: string;
  className: string;
  activeCount: number;
  lockedAt: string | null;
  candidates: CandidateRow[];
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

function ScoreEntryForm({ candidateId }: { candidateId: string }) {
  const [pending, startTransition] = useTransition();
  const [subjectCode, setSubjectCode] = useState('');
  const [obtained, setObtained] = useState('');
  const [total, setTotal] = useState('');

  const onSave = () => {
    const fd = new FormData();
    fd.set('candidateId', candidateId);
    fd.set('subjectCode', subjectCode);
    fd.set('obtained', obtained);
    fd.set('total', total);
    startTransition(async () => {
      const result = await setTestScore({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Score saved.');
        setSubjectCode('');
        setObtained('');
        setTotal('');
      }
    });
  };

  return (
    <div className="flex items-center gap-1">
      <Input
        placeholder="Subject"
        className="h-7 w-24"
        value={subjectCode}
        onChange={(e) => setSubjectCode(e.target.value)}
        data-testid={`score-subject-${candidateId}`}
      />
      <Input
        placeholder="Obt."
        type="number"
        className="h-7 w-16"
        value={obtained}
        onChange={(e) => setObtained(e.target.value)}
        data-testid={`score-obtained-${candidateId}`}
      />
      <Input
        placeholder="Total"
        type="number"
        className="h-7 w-16"
        value={total}
        onChange={(e) => setTotal(e.target.value)}
        data-testid={`score-total-${candidateId}`}
      />
      <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onSave} data-testid={`score-save-${candidateId}`}>
        Save
      </Button>
    </div>
  );
}

function AttendanceSelect({ candidateId, attendance }: { candidateId: string; attendance: string }) {
  const [pending, startTransition] = useTransition();

  const onChange = (value: string) => {
    startTransition(async () => {
      const result = await setTestAttendance(candidateId, value);
      if (result.error) toast.error(result.error);
      else toast.success('Attendance updated.');
    });
  };

  return (
    <Select value={attendance} onValueChange={onChange} disabled={pending}>
      <SelectTrigger className="h-7 w-24" data-testid={`attendance-trigger-${candidateId}`}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {TEST_ATTENDANCES.map((a) => (
          <SelectItem key={a} value={a}>
            {a}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function MeritPanel({ sittingId, lockedAt, candidates }: { sittingId: string; lockedAt: string | null; candidates: CandidateRow[] }) {
  const [pending, startTransition] = useTransition();

  const onPublish = () => {
    startTransition(async () => {
      const result = await publishMeritList(sittingId);
      if (result.error) toast.error(result.error);
      else toast.success('Merit list published.');
    });
  };

  const onUnlock = () => {
    startTransition(async () => {
      const result = await unlockTestScores(sittingId);
      if (result.error) toast.error(result.error);
      else toast.success('Sitting unlocked.');
    });
  };

  if (candidates.length === 0) return null;

  return (
    <div className="mt-2 space-y-2 border-t pt-2" data-testid={`merit-panel-${sittingId}`}>
      <div className="flex items-center gap-2">
        <span className="text-xs text-muted-foreground" data-testid={`sitting-lock-status-${sittingId}`}>
          {lockedAt ? 'Published (locked)' : 'Not published'}
        </span>
        {lockedAt ? (
          <Button type="button" size="sm" variant="outline" disabled={pending} onClick={onUnlock}>
            Unlock
          </Button>
        ) : (
          <Button type="button" size="sm" disabled={pending} onClick={onPublish}>
            Publish merit list
          </Button>
        )}
      </div>
      <div className="space-y-1">
        {candidates.map((c) => (
          <div key={c.id} className="flex flex-wrap items-center gap-2 text-xs" data-testid={`candidate-row-${c.id}`}>
            <span className="w-32 shrink-0">
              Seat {c.seatNo} — {c.childName}
            </span>
            <AttendanceSelect candidateId={c.id} attendance={c.attendance} />
            {c.merit && (
              <span data-testid={`candidate-rank-${c.id}`}>
                Rank {c.merit.rnk} · {c.merit.pct}% ({c.merit.tieBreakBasis})
              </span>
            )}
            {!lockedAt && <ScoreEntryForm candidateId={c.id} />}
          </div>
        ))}
      </div>
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
            <MeritPanel sittingId={s.id} lockedAt={s.lockedAt} candidates={s.candidates} />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
