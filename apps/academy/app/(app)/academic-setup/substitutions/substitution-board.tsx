'use client';

import { useEffect, useState, useTransition } from 'react';
import { toast } from 'sonner';
import {
  loadAbsentTeachers,
  loadPeriodsForTeacher,
  loadCandidates,
  loadReviewWorklist,
  assignSubstitution,
  type AbsentTeacher,
  type PeriodRow,
  type Candidate,
  type ReviewRow,
} from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Card, CardContent } from '@/components/ui/card';
import { DatePicker } from '@/components/ui/date-picker';

function todayIso() {
  return new Date().toISOString().slice(0, 10);
}

// AC's own Notes: leave -> 'leave', suspension has no attendance-status
// equivalent so it's never auto-picked, only 'other'/'official_duty' are
// reachable from a manual absence mark.
function defaultReason(status: string): 'leave' | 'other' {
  return status === 'on_leave' ? 'leave' : 'other';
}

function CandidateRow({ candidate, onPick, disabled }: { candidate: Candidate; onPick: () => void; disabled: boolean }) {
  const slug = candidate.fullName.replace(/\s+/g, '-');
  return (
    <button
      type="button"
      onClick={onPick}
      disabled={disabled}
      data-testid={`sub-candidate-${slug}`}
      className="flex w-full items-center justify-between rounded-md border px-3 py-2 text-left text-sm hover:bg-muted disabled:opacity-50"
    >
      <span>{candidate.fullName}</span>
      <span className="flex gap-1 text-xs text-muted-foreground">
        {!candidate.isFree && <span className="rounded bg-red-100 px-1.5 py-0.5 text-red-800">busy</span>}
        {candidate.canTeachSubject && <span className="rounded bg-blue-100 px-1.5 py-0.5 text-blue-800">qualified</span>}
        <span>{candidate.periodsCoveredToday} covered today</span>
      </span>
    </button>
  );
}

function PeriodCard({ campusId, period, subDate, onAssigned }: { campusId: string; period: PeriodRow; subDate: string; onAssigned: () => void }) {
  const [pending, startTransition] = useTransition();
  const [expanded, setExpanded] = useState(false);
  const [candidates, setCandidates] = useState<Candidate[]>([]);

  const onFill = () => {
    if (expanded) {
      setExpanded(false);
      return;
    }
    startTransition(async () => {
      const result = await loadCandidates(period.slotId, subDate);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setCandidates(result.candidates);
      setExpanded(true);
    });
  };

  const onPick = (staffId: string) => {
    startTransition(async () => {
      const result = await assignSubstitution({ slotId: period.slotId, subDate, substituteStaffId: staffId, reason: 'other' });
      if (result.error) {
        toast.error(result.error);
        return;
      }
      toast.success('Substitute assigned.');
      setExpanded(false);
      onAssigned();
    });
  };

  return (
    <Card data-testid={`sub-period-${period.periodNo}`}>
      <CardContent className="space-y-2 p-4">
        <div className="flex items-center justify-between">
          <div>
            <p className="font-medium">
              Period {period.periodNo} — {period.subjectCode} — {period.sectionName}
            </p>
            {period.substituteName ? (
              <p className="text-sm text-muted-foreground" data-testid={`sub-status-${period.periodNo}`}>
                Covered by {period.substituteName}
                {period.substitutionStatus === 'review' ? ' — needs review (leave was cancelled)' : ''}
              </p>
            ) : (
              <p className="text-sm text-muted-foreground" data-testid={`sub-status-${period.periodNo}`}>
                Uncovered
              </p>
            )}
          </div>
          <Button type="button" variant="outline" size="sm" onClick={onFill} disabled={pending} data-testid={`sub-fill-${period.periodNo}`}>
            {expanded ? 'Close' : period.substituteName ? 'Reassign' : 'Fill'}
          </Button>
        </div>
        {expanded && (
          <div className="space-y-1 border-t pt-2">
            {candidates.length === 0 ? (
              <p className="text-sm text-muted-foreground">No eligible teachers found.</p>
            ) : (
              candidates.map((c) => <CandidateRow key={c.staffId} candidate={c} onPick={() => onPick(c.staffId)} disabled={pending} />)
            )}
          </div>
        )}
      </CardContent>
    </Card>
  );
}

export function SubstitutionBoard({ campusId }: { campusId: string }) {
  const [pending, startTransition] = useTransition();
  const [subDate, setSubDate] = useState(todayIso());
  const [teachers, setTeachers] = useState<AbsentTeacher[]>([]);
  const [selectedTeacher, setSelectedTeacher] = useState<AbsentTeacher | null>(null);
  const [periods, setPeriods] = useState<PeriodRow[]>([]);
  const [reviewRows, setReviewRows] = useState<ReviewRow[]>([]);
  const [loadedOnce, setLoadedOnce] = useState(false);

  const refreshReview = () => {
    startTransition(async () => {
      const result = await loadReviewWorklist(campusId);
      if (result.error) toast.error(result.error);
      else setReviewRows(result.rows);
    });
  };

  useEffect(() => {
    refreshReview();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [campusId]);

  const onLoadTeachers = () => {
    startTransition(async () => {
      const result = await loadAbsentTeachers(campusId, subDate);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setTeachers(result.teachers);
      setSelectedTeacher(null);
      setPeriods([]);
      setLoadedOnce(true);
    });
  };

  const onSelectTeacher = (teacher: AbsentTeacher) => {
    startTransition(async () => {
      const result = await loadPeriodsForTeacher(campusId, teacher.staffUserId, subDate);
      if (result.error) {
        toast.error(result.error);
        return;
      }
      setSelectedTeacher(teacher);
      setPeriods(result.periods);
    });
  };

  const refreshPeriods = () => {
    if (!selectedTeacher) return;
    startTransition(async () => {
      const result = await loadPeriodsForTeacher(campusId, selectedTeacher.staffUserId, subDate);
      if (!result.error) setPeriods(result.periods);
    });
    refreshReview();
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end gap-2 rounded-lg border p-4">
        <div className="space-y-1">
          <Label htmlFor="sub-date">Date</Label>
          <DatePicker id="sub-date" value={subDate} onChange={setSubDate} data-testid="sub-date-input" />
        </div>
        <Button type="button" onClick={onLoadTeachers} disabled={pending} data-testid="sub-load-button">
          Load absences
        </Button>
      </div>

      {loadedOnce && (
        <div className="space-y-2">
          <h2 className="text-sm font-medium text-muted-foreground">Absent today</h2>
          {teachers.length === 0 ? (
            <p className="text-sm text-muted-foreground">No teacher is marked absent or on leave for this date.</p>
          ) : (
            <div className="flex flex-wrap gap-2">
              {teachers.map((t) => (
                <Button
                  key={t.staffUserId}
                  type="button"
                  variant={selectedTeacher?.staffUserId === t.staffUserId ? 'default' : 'outline'}
                  onClick={() => onSelectTeacher(t)}
                  data-testid={`absent-teacher-${t.fullName.replace(/\s+/g, '-')}`}
                >
                  {t.fullName}
                </Button>
              ))}
            </div>
          )}
        </div>
      )}

      {selectedTeacher && (
        <div className="space-y-2">
          <h2 className="text-sm font-medium text-muted-foreground">{selectedTeacher.fullName}&apos;s periods</h2>
          {periods.length === 0 ? (
            <p className="text-sm text-muted-foreground">No timetabled periods on this weekday.</p>
          ) : (
            <div className="space-y-2">
              {periods.map((p) => (
                <PeriodCard key={p.slotId} campusId={campusId} period={p} subDate={subDate} onAssigned={refreshPeriods} />
              ))}
            </div>
          )}
        </div>
      )}

      {reviewRows.length > 0 && (
        <div className="space-y-2" data-testid="sub-review-worklist">
          <h2 className="text-sm font-medium text-muted-foreground">Needs review — leave was cancelled after assignment</h2>
          {reviewRows.map((r) => (
            <Card key={r.id} data-testid={`sub-review-row-${r.id}`}>
              <CardContent className="p-4 text-sm">
                {r.subDate} · Period {r.periodNo} · {r.subjectCode} · {r.sectionName} — {r.absentName} covered by {r.substituteName}
              </CardContent>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}
