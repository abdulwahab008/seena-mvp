'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import { loadRegisterRoster, bulkMarkAttendance, lockAttendanceNow, requestAttendanceCorrection, type RosterStudent } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

// FR-G04: present -> absent -> late -> excused -> present, one tap, no
// dialog, no dropdown. The AC's own cycle names the 4th state "leave" —
// this schema's enum (FR-G02) calls the same concept 'excused'.
const CYCLE = ['present', 'absent', 'late', 'excused'] as const;

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

function StatusButton({ status, onTap }: { status: string; onTap: () => void }) {
  const colors: Record<string, string> = {
    present: 'bg-green-100 text-green-800 border-green-300',
    absent: 'bg-red-100 text-red-800 border-red-300',
    late: 'bg-amber-100 text-amber-800 border-amber-300',
    excused: 'bg-blue-100 text-blue-800 border-blue-300',
  };
  return (
    <button
      type="button"
      onClick={onTap}
      className={`min-h-11 min-w-11 rounded-md border px-3 py-2 text-sm font-medium capitalize ${colors[status] ?? ''}`}
      data-testid="register-status-tap"
    >
      {status.replace(/_/g, ' ')}
    </button>
  );
}

function CorrectionRequestControl({ enrolmentId, attendanceDate }: { enrolmentId: string; attendanceDate: string }) {
  const [pending, startTransition] = useTransition();
  const [open, setOpen] = useState(false);
  const [newStatus, setNewStatus] = useState<(typeof CYCLE)[number]>('present');
  const [reason, setReason] = useState('');

  const onSubmit = () => {
    const fd = new FormData();
    fd.set('enrolmentId', enrolmentId);
    fd.set('attendanceDate', attendanceDate);
    fd.set('newStatus', newStatus);
    fd.set('reason', reason);
    startTransition(async () => {
      const result = await requestAttendanceCorrection({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Correction requested.');
        setOpen(false);
        setReason('');
      }
    });
  };

  if (!open) {
    return (
      <Button type="button" size="sm" variant="outline" onClick={() => setOpen(true)} data-testid={`request-correction-open-${enrolmentId}`}>
        Request correction
      </Button>
    );
  }

  return (
    <div className="flex flex-wrap items-center gap-1">
      <Select value={newStatus} onValueChange={(v) => setNewStatus(v as (typeof CYCLE)[number])}>
        <SelectTrigger className="h-8 w-28" data-testid={`correction-status-trigger-${enrolmentId}`}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {CYCLE.map((s) => (
            <SelectItem key={s} value={s}>
              {s.replace(/_/g, ' ')}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Input
        placeholder="Reason (min 10 chars)"
        className="h-8 w-56"
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        data-testid={`correction-reason-${enrolmentId}`}
      />
      <Button type="button" size="sm" disabled={pending} onClick={onSubmit} data-testid={`correction-submit-${enrolmentId}`}>
        Submit
      </Button>
    </div>
  );
}

export function RegisterForm({
  campusId,
  sections,
  isAdmin,
}: {
  campusId: string;
  sections: { id: string; label: string }[];
  isAdmin: boolean;
}) {
  const [pending, startTransition] = useTransition();
  const [sectionId, setSectionId] = useState(sections[0]?.id ?? '');
  const [attendanceDate, setAttendanceDate] = useState(todayIso());
  const [holiday, setHoliday] = useState<string | null>(null);
  const [students, setStudents] = useState<RosterStudent[]>([]);
  const [marks, setMarks] = useState<Record<string, string>>({});
  const [loaded, setLoaded] = useState(false);
  const [locked, setLocked] = useState(false);
  const [lockedAt, setLockedAt] = useState<string | null>(null);

  const onLoad = () => {
    if (!sectionId || !attendanceDate) return;
    startTransition(async () => {
      const result = await loadRegisterRoster(campusId, sectionId, attendanceDate);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setHoliday(result.holiday);
      setStudents(result.students);
      setMarks(Object.fromEntries(result.students.map((s) => [s.enrolmentId, s.currentStatus ?? 'present'])));
      setLocked(result.locked);
      setLockedAt(result.lockedAt);
      setLoaded(true);
    });
  };

  const onLockNow = () => {
    startTransition(async () => {
      const result = await lockAttendanceNow(sectionId, attendanceDate);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Locked.');
        onLoad();
      }
    });
  };

  const onTap = (enrolmentId: string) => {
    setMarks((m) => {
      const current = m[enrolmentId] ?? 'present';
      const next = CYCLE[(CYCLE.indexOf(current as (typeof CYCLE)[number]) + 1) % CYCLE.length] ?? 'present';
      return { ...m, [enrolmentId]: next };
    });
  };

  const onSave = () => {
    // AC1: only the exceptions travel — every un-touched student stays
    // present server-side, so a zero-touch submit is a tiny fixed payload.
    const exceptions = students
      .map((s) => ({ enrolmentId: s.enrolmentId, status: marks[s.enrolmentId] ?? 'present' }))
      .filter((m) => m.status !== 'present');

    const fd = new FormData();
    fd.set('sectionId', sectionId);
    fd.set('attendanceDate', attendanceDate);
    fd.set('exceptions', JSON.stringify(exceptions));
    startTransition(async () => {
      const result = await bulkMarkAttendance({ error: null, saved: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success(`Register saved — ${result.saved} student(s).`);
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="section">Section</Label>
          <Select value={sectionId} onValueChange={setSectionId}>
            <SelectTrigger id="section" className="w-48" data-testid="register-section-trigger">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {sections.map((s) => (
                <SelectItem key={s.id} value={s.id}>
                  {s.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="space-y-1">
          <Label htmlFor="attendanceDate">Date</Label>
          <Input
            id="attendanceDate"
            type="date"
            value={attendanceDate}
            onChange={(e) => setAttendanceDate(e.target.value)}
            data-testid="register-date"
          />
        </div>
        <Button type="button" disabled={pending} onClick={onLoad} data-testid="register-load">
          Load register
        </Button>
      </div>

      {loaded && holiday && (
        <p className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-800" data-testid="register-holiday-banner">
          {holiday} — this is a declared holiday. The register is read-only.
        </p>
      )}

      {loaded && !holiday && locked && (
        <p className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800" data-testid="register-locked-banner">
          Locked{lockedAt ? ` at ${new Date(lockedAt).toLocaleString()}` : ''} — this date can no longer be edited.
        </p>
      )}

      {loaded && !holiday && (
        <div className="space-y-2">
          {students.length === 0 ? (
            <p className="text-sm text-muted-foreground">No active students in this section.</p>
          ) : (
            <ul className="divide-y rounded-lg border">
              {students.map((s) => (
                <li
                  key={s.enrolmentId}
                  className="flex min-h-12 items-center justify-between gap-2 p-3 text-sm"
                  data-testid={`register-row-${s.enrolmentId}`}
                >
                  <span>
                    {s.name} <span className="text-muted-foreground">({s.grNumber})</span>
                  </span>
                  {locked ? (
                    <div className="flex items-center gap-2">
                      <span className="text-xs capitalize text-muted-foreground" data-testid={`register-current-status-${s.enrolmentId}`}>
                        {(s.currentStatus ?? 'present').replace(/_/g, ' ')}
                      </span>
                      <CorrectionRequestControl enrolmentId={s.enrolmentId} attendanceDate={attendanceDate} />
                    </div>
                  ) : (
                    <StatusButton status={marks[s.enrolmentId] ?? 'present'} onTap={() => onTap(s.enrolmentId)} />
                  )}
                </li>
              ))}
            </ul>
          )}
          {students.length > 0 && !locked && (
            <Button type="button" disabled={pending} onClick={onSave} data-testid="register-save">
              {pending ? 'Saving…' : 'Save register'}
            </Button>
          )}
          {isAdmin && !locked && (
            <Button type="button" variant="outline" disabled={pending} onClick={onLockNow} data-testid="register-lock-now">
              Lock now
            </Button>
          )}
        </div>
      )}
    </div>
  );
}
