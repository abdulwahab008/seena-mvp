'use client';

import { useState, useTransition } from 'react';
import { toast } from 'sonner';
import Link from 'next/link';
import {
  CalendarDays,
  Users,
  MapPin,
  CheckCircle2,
  Lock,
  Unlock,
  Printer,
  FileText,
  Search,
  Award,
  BookOpen,
  Sparkles,
  ClipboardList,
  AlertCircle,
  ArrowUpRight,
  PlusCircle,
} from 'lucide-react';
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
import { Modal } from '@/components/ui/modal';

export type CandidateRow = {
  id: string;
  seatNo: number;
  applicationNo?: string | null;
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

export type EligibleApplication = {
  id: string;
  applicationNo: string | null;
  childName: string;
  classAppliedId: string;
};

function AllocateSeatForm({
  sittingId,
  applications,
  capacity,
  activeCount,
}: {
  sittingId: string;
  applications: EligibleApplication[];
  capacity: number;
  activeCount: number;
}) {
  const [pending, startTransition] = useTransition();
  const [applicationId, setApplicationId] = useState('');
  const remaining = capacity - activeCount;

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

  if (applications.length === 0) {
    return (
      <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
        <span>No unallocated applications for this class</span>
        <span className="text-muted-foreground/30">·</span>
        <Link
          href="/admissions/applications"
          className="text-[11px] font-medium text-primary hover:underline inline-flex items-center gap-0.5"
        >
          Applications
          <ArrowUpRight className="h-3 w-3" />
        </Link>
        <span className="text-muted-foreground/30">·</span>
        <Link
          href="/admissions/enquiries"
          className="text-[11px] font-medium text-primary hover:underline inline-flex items-center gap-0.5"
        >
          New Enquiry
          <PlusCircle className="h-3 w-3" />
        </Link>
      </div>
    );
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <Select value={applicationId} onValueChange={setApplicationId}>
        <SelectTrigger className="h-8 w-60 text-xs bg-background" data-testid={`allocate-app-trigger-${sittingId}`}>
          <SelectValue placeholder="Select candidate application" />
        </SelectTrigger>
        <SelectContent>
          {applications.map((a) => (
            <SelectItem key={a.id} value={a.id} className="text-xs">
              {a.childName} {a.applicationNo ? `(${a.applicationNo})` : ''}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button
        type="button"
        size="sm"
        disabled={pending}
        onClick={onAllocate}
        className="h-8 text-xs font-medium"
      >
        {pending ? 'Allocating…' : 'Allocate seat'}
      </Button>
    </div>
  );
}

function RollSlipViewer({
  sittingId,
  className,
  startsAt,
  venue,
  campusName,
}: {
  sittingId: string;
  className: string;
  startsAt: string;
  venue: string | null;
  campusName: string;
}) {
  const [pending, startTransition] = useTransition();
  const [payload, setPayload] = useState<RollSlipPayload | null>(null);
  const [printModalOpen, setPrintModalOpen] = useState(false);

  const onView = () => {
    startTransition(async () => {
      const result = await fetchRollSlip(sittingId);
      if (result.error) toast.error(result.error);
      else setPayload(result.payload);
    });
  };

  return (
    <div className="mt-2.5 space-y-2 border-t pt-2.5">
      <div className="flex items-center justify-between">
        <Button
          type="button"
          size="sm"
          variant="outline"
          disabled={pending}
          onClick={onView}
          className="h-7 gap-1.5 text-xs font-medium"
        >
          <FileText className="h-3 w-3 text-muted-foreground" />
          {pending ? 'Loading roll slip…' : 'View roll slip'}
        </Button>

        {payload && payload.candidates.length > 0 && (
          <Button
            type="button"
            size="sm"
            variant="secondary"
            onClick={() => setPrintModalOpen(true)}
            className="h-7 gap-1.5 text-xs font-medium"
          >
            <Printer className="h-3 w-3" />
            Print Official Slips
          </Button>
        )}
      </div>

      {payload && (
        <div className="rounded-lg border bg-muted/20 p-2.5">
          {payload.candidates.length === 0 ? (
            <p className="text-xs text-muted-foreground" data-testid={`roll-slip-${sittingId}`}>
              No candidates seated yet in this sitting.
            </p>
          ) : (
            <>
              <div className="flex items-center justify-between pb-1.5 border-b mb-2">
                <span className="text-xs font-semibold text-foreground">
                  Candidate Seating Register ({payload.candidates.length} {payload.candidates.length === 1 ? 'candidate' : 'candidates'})
                </span>
                <span className="text-[11px] text-muted-foreground">
                  Venue: {payload.venue ?? 'Main Hall'}
                </span>
              </div>
              <ul className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 gap-1.5 text-xs" data-testid={`roll-slip-${sittingId}`}>
                {payload.candidates.map((c) => (
                  <li
                    key={c.seat_no}
                    className="flex items-center justify-between rounded-md bg-background px-2.5 py-1 border shadow-xs"
                  >
                    <span className="font-semibold text-primary">Seat {c.seat_no} — {c.child_name}</span>
                    <span className="text-[11px] text-muted-foreground font-mono">({c.application_no})</span>
                  </li>
                ))}
              </ul>
            </>
          )}
        </div>
      )}

      {/* Printable Roll Slip Modal */}
      {payload && (
        <Modal
          open={printModalOpen}
          onClose={() => setPrintModalOpen(false)}
          title="Admission Test Entry Pass / Roll Number Slips"
          description={`Official test slips for ${className} · ${campusName}`}
          size="lg"
          footer={
            <div className="flex items-center gap-2">
              <Button variant="outline" size="sm" onClick={() => setPrintModalOpen(false)}>
                Close
              </Button>
              <Button size="sm" onClick={() => window.print()} className="gap-1.5">
                <Printer className="h-4 w-4" />
                Print Slips
              </Button>
            </div>
          }
        >
          <div className="space-y-4 py-2">
            <p className="text-xs text-muted-foreground">
              Each candidate must present this entry slip with proof of identity on the test day.
            </p>
            <div className="space-y-4">
              {payload.candidates.map((c) => (
                <div key={c.seat_no} className="rounded-xl border-2 border-dashed border-border/80 p-4 bg-muted/10 space-y-3">
                  <div className="flex items-center justify-between border-b pb-2">
                    <div>
                      <h4 className="font-bold text-sm tracking-tight text-foreground">{campusName}</h4>
                      <p className="text-[11px] text-muted-foreground uppercase font-semibold">Admission Entry Assessment</p>
                    </div>
                    <div className="text-right">
                      <span className="rounded-full bg-primary/10 text-primary font-bold text-xs px-2.5 py-0.5 border border-primary/20">
                        ROLL / SEAT #{c.seat_no}
                      </span>
                    </div>
                  </div>

                  <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
                    <div>
                      <span className="text-muted-foreground block text-[10px]">Candidate Name</span>
                      <span className="font-bold text-foreground text-sm">{c.child_name}</span>
                    </div>
                    <div>
                      <span className="text-muted-foreground block text-[10px]">Application No</span>
                      <span className="font-mono font-semibold text-foreground">{c.application_no ?? 'N/A'}</span>
                    </div>
                    <div>
                      <span className="text-muted-foreground block text-[10px]">Class Applied</span>
                      <span className="font-semibold text-foreground">{className}</span>
                    </div>
                    <div>
                      <span className="text-muted-foreground block text-[10px]">Test Venue</span>
                      <span className="font-semibold text-foreground">{venue ?? 'Main Hall'}</span>
                    </div>
                  </div>

                  <div className="rounded-lg bg-background p-2.5 text-[11px] text-muted-foreground border">
                    <span className="font-semibold text-foreground mr-1">Instructions:</span>
                    Arrive 15 minutes before scheduled start ({new Date(startsAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}). Bring clipboard, blue pen/pencil, and eraser. Electronic devices are strictly prohibited.
                  </div>
                </div>
              ))}
            </div>
          </div>
        </Modal>
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
    <div className="flex flex-wrap items-center gap-1.5">
      {/* Quick Subject Suggestions */}
      <div className="hidden sm:flex items-center gap-1">
        {['math', 'english', 'science'].map((sub) => (
          <button
            key={sub}
            type="button"
            onClick={() => {
              setSubjectCode(sub);
              setTotal('50');
            }}
            className="rounded bg-muted/60 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-muted-foreground hover:bg-muted"
          >
            {sub}
          </button>
        ))}
      </div>

      <Input
        placeholder="Subject"
        className="h-7 w-22 text-xs font-medium"
        value={subjectCode}
        onChange={(e) => setSubjectCode(e.target.value)}
        data-testid={`score-subject-${candidateId}`}
      />
      <Input
        placeholder="Obt."
        type="number"
        className="h-7 w-15 text-xs font-semibold"
        value={obtained}
        onChange={(e) => setObtained(e.target.value)}
        data-testid={`score-obtained-${candidateId}`}
      />
      <Input
        placeholder="Total"
        type="number"
        className="h-7 w-15 text-xs font-semibold"
        value={total}
        onChange={(e) => setTotal(e.target.value)}
        data-testid={`score-total-${candidateId}`}
      />
      <Button
        type="button"
        size="sm"
        variant="outline"
        disabled={pending}
        onClick={onSave}
        className="h-7 px-2.5 text-xs font-medium"
        data-testid={`score-save-${candidateId}`}
      >
        {pending ? 'Saving…' : 'Save'}
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

  const getBadgeColor = (status: string) => {
    if (status === 'present') return 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border-emerald-500/20';
    if (status === 'absent') return 'bg-rose-500/10 text-rose-600 dark:text-rose-400 border-rose-500/20';
    return 'bg-amber-500/10 text-amber-600 dark:text-amber-400 border-amber-500/20';
  };

  return (
    <Select value={attendance} onValueChange={onChange} disabled={pending}>
      <SelectTrigger
        className={`h-7 w-26 text-xs font-medium capitalize border ${getBadgeColor(attendance)}`}
        data-testid={`attendance-trigger-${candidateId}`}
      >
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        {TEST_ATTENDANCES.map((a) => (
          <SelectItem key={a} value={a} className="capitalize text-xs">
            {a}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}

function MeritPanel({
  sittingId,
  lockedAt,
  candidates,
}: {
  sittingId: string;
  lockedAt: string | null;
  candidates: CandidateRow[];
}) {
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
    <div className="mt-4 space-y-3 border-t pt-3" data-testid={`merit-panel-${sittingId}`}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <Award className="h-4 w-4 text-primary" />
          <span className="text-xs font-semibold text-foreground">Candidate Assessment & Merit Roster</span>
          <span
            className={`rounded-full px-2 py-0.5 text-[11px] font-semibold border ${
              lockedAt
                ? 'bg-emerald-500/10 text-emerald-600 dark:text-emerald-400 border-emerald-500/20'
                : 'bg-muted text-muted-foreground border-border'
            }`}
            data-testid={`sitting-lock-status-${sittingId}`}
          >
            {lockedAt ? 'Published (locked)' : 'Not published'}
          </span>
        </div>

        {lockedAt ? (
          <Button
            type="button"
            size="sm"
            variant="outline"
            disabled={pending}
            onClick={onUnlock}
            className="h-8 gap-1 text-xs font-medium border-amber-500/30 text-amber-600 hover:bg-amber-500/10"
          >
            <Unlock className="h-3.5 w-3.5" />
            {pending ? 'Unlocking…' : 'Unlock'}
          </Button>
        ) : (
          <Button
            type="button"
            size="sm"
            disabled={pending}
            onClick={onPublish}
            className="h-8 gap-1.5 text-xs font-semibold bg-emerald-600 hover:bg-emerald-700 text-white"
          >
            <Award className="h-3.5 w-3.5" />
            {pending ? 'Publishing…' : 'Publish merit list'}
          </Button>
        )}
      </div>

      {/* Candidate Rows */}
      <div className="space-y-2">
        {candidates.map((c) => (
          <div
            key={c.id}
            className="flex flex-col gap-2 rounded-lg border bg-background p-3 shadow-xs transition-colors hover:border-border sm:flex-row sm:items-center sm:justify-between"
            data-testid={`candidate-row-${c.id}`}
          >
            <div className="flex items-center gap-3">
              <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-full bg-primary/10 text-xs font-bold text-primary">
                {c.seatNo}
              </span>
              <div>
                <div className="flex items-center gap-2">
                  <span className="font-semibold text-sm text-foreground">Seat {c.seatNo} — {c.childName}</span>
                  {c.applicationNo && (
                    <span className="text-[11px] font-mono text-muted-foreground">({c.applicationNo})</span>
                  )}
                </div>

                {/* Existing Scores Summary */}
                {c.scores.length > 0 ? (
                  <div className="flex flex-wrap items-center gap-1.5 pt-1">
                    {c.scores.map((s, idx) => (
                      <span
                        key={idx}
                        className="rounded bg-muted px-1.5 py-0.5 text-[10px] font-medium text-foreground uppercase"
                      >
                        {s.subjectCode}: <strong className="font-bold">{s.obtained}</strong>/{s.total}
                      </span>
                    ))}
                  </div>
                ) : (
                  <p className="text-[11px] text-muted-foreground pt-0.5">No subject marks recorded yet</p>
                )}
              </div>
            </div>

            <div className="flex flex-wrap items-center gap-2.5 self-end sm:self-auto">
              <AttendanceSelect candidateId={c.id} attendance={c.attendance} />

              {c.merit && (
                <div
                  className="flex items-center gap-1.5 rounded-md bg-primary/10 px-2 py-1 text-xs font-semibold text-primary border border-primary/20"
                  data-testid={`candidate-rank-${c.id}`}
                >
                  <Award className="h-3.5 w-3.5 text-primary" />
                  <span>
                    Rank {c.merit.rnk} · {c.merit.pct}% ({c.merit.tieBreakBasis})
                  </span>
                </div>
              )}

              {!lockedAt && <ScoreEntryForm candidateId={c.id} />}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export function SittingList({
  sittings,
  applications,
  campusName = 'Main Campus',
  sessionName = 'Academic Session',
}: {
  sittings: SittingRow[];
  applications: EligibleApplication[];
  campusName?: string;
  sessionName?: string;
}) {
  const [searchQuery, setSearchQuery] = useState('');
  const [filterMode, setFilterMode] = useState<'all' | 'pending' | 'published'>('all');

  // KPI Metrics
  const totalSittings = sittings.length;
  const totalSeated = sittings.reduce((acc, s) => acc + s.activeCount, 0);
  const totalCapacity = sittings.reduce((acc, s) => acc + s.capacity, 0);
  const totalPublished = sittings.filter((s) => s.lockedAt !== null).length;
  const pendingEvaluation = sittings.filter((s) => s.activeCount > 0 && s.lockedAt === null).length;

  const filteredSittings = sittings.filter((s) => {
    if (filterMode === 'pending' && s.lockedAt !== null) return false;
    if (filterMode === 'published' && s.lockedAt === null) return false;
    if (searchQuery.trim()) {
      const q = searchQuery.toLowerCase();
      const matchClass = s.className.toLowerCase().includes(q);
      const matchVenue = (s.venue ?? '').toLowerCase().includes(q);
      const matchCandidate = s.candidates.some((c) => c.childName.toLowerCase().includes(q));
      return matchClass || matchVenue || matchCandidate;
    }
    return true;
  });

  return (
    <div className="space-y-4">
      {/* Executive Minimalist Toolbar & Inline Metrics */}
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between border-b pb-3">
        <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
          <span className="font-semibold text-foreground flex items-center gap-1.5">
            <CalendarDays className="h-3.5 w-3.5 text-primary" />
            {totalSittings} {totalSittings === 1 ? 'Sitting' : 'Sittings'}
          </span>
          <span className="text-muted-foreground/30">•</span>
          <span className="text-foreground/80 font-medium">
            <strong className="font-semibold text-foreground">{totalSeated}</strong>/{totalCapacity} Seats Filled
          </span>
          {pendingEvaluation > 0 && (
            <>
              <span className="text-muted-foreground/30">•</span>
              <span className="text-amber-600 dark:text-amber-400 font-medium">
                {pendingEvaluation} Needs Scoring
              </span>
            </>
          )}
          {totalPublished > 0 && (
            <>
              <span className="text-muted-foreground/30">•</span>
              <span className="text-emerald-600 dark:text-emerald-400 font-medium">
                {totalPublished} Published
              </span>
            </>
          )}
          <span className="text-muted-foreground/30">•</span>
          <span className="text-muted-foreground">
            {applications.length} unassigned {applications.length === 1 ? 'applicant' : 'applicants'}
          </span>
        </div>

        {/* Filter Pills & Search */}
        {sittings.length > 0 && (
          <div className="flex flex-wrap items-center gap-2">
            <div className="flex items-center rounded-lg border bg-muted/40 p-0.5 text-xs">
              <button
                type="button"
                onClick={() => setFilterMode('all')}
                className={`rounded px-2.5 py-1 font-medium transition-all ${
                  filterMode === 'all'
                    ? 'bg-background text-foreground shadow-xs'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                All ({totalSittings})
              </button>
              <button
                type="button"
                onClick={() => setFilterMode('pending')}
                className={`rounded px-2.5 py-1 font-medium transition-all ${
                  filterMode === 'pending'
                    ? 'bg-background text-foreground shadow-xs'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                Needs Scoring ({pendingEvaluation})
              </button>
              <button
                type="button"
                onClick={() => setFilterMode('published')}
                className={`rounded px-2.5 py-1 font-medium transition-all ${
                  filterMode === 'published'
                    ? 'bg-background text-foreground shadow-xs'
                    : 'text-muted-foreground hover:text-foreground'
                }`}
              >
                Published ({totalPublished})
              </button>
            </div>

            <div className="relative w-44 sm:w-52">
              <Search className="absolute left-2.5 top-2 h-3.5 w-3.5 text-muted-foreground" />
              <Input
                placeholder="Search sittings..."
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                className="h-7.5 pl-8 text-xs bg-card"
              />
            </div>
          </div>
        )}
      </div>

      {/* Empty State */}
      {sittings.length === 0 ? (
        <Card className="border-dashed">
          <CardContent className="flex flex-col items-center justify-center p-8 text-center">
            <div className="flex h-10 w-10 items-center justify-center rounded-full bg-primary/10 text-primary mb-2.5">
              <CalendarDays className="h-5 w-5" />
            </div>
            <p className="text-sm font-semibold text-foreground">No test sittings scheduled yet.</p>
            <p className="text-xs text-muted-foreground max-w-sm mt-1">
              Use the schedule form above to configure your first exam sitting.
            </p>
          </CardContent>
        </Card>
      ) : filteredSittings.length === 0 ? (
        <Card className="border-dashed">
          <CardContent className="p-6 text-center text-xs text-muted-foreground">
            No test sittings match your current filter or search.
          </CardContent>
        </Card>
      ) : (
        <div className="space-y-3">
          {filteredSittings.map((s) => {
            const pctFilled = Math.min(100, Math.round((s.activeCount / s.capacity) * 100));
            const formattedDate = new Date(s.startsAt).toLocaleString(undefined, {
              dateStyle: 'medium',
              timeStyle: 'short',
            });

            return (
              <Card key={s.id} data-testid={`sitting-row-${s.id}`} className="overflow-hidden shadow-xs hover:border-primary/30 transition-all">
                <CardContent className="p-4 space-y-3">
                  {/* Sitting Header Row */}
                  <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between pb-3 border-b">
                    <div className="space-y-1">
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="rounded bg-primary/10 px-2 py-0.5 text-xs font-bold text-primary">
                          {s.className}
                        </span>
                        <span className="text-xs font-semibold text-foreground flex items-center gap-1">
                          <CalendarDays className="h-3.5 w-3.5 text-muted-foreground" />
                          {formattedDate}
                        </span>
                        {s.lockedAt ? (
                          <span className="flex items-center gap-1 rounded-full bg-emerald-500/10 px-2 py-0.2 text-[10px] font-semibold text-emerald-600 dark:text-emerald-400 border border-emerald-500/20">
                            <Lock className="h-3 w-3" />
                            Merit Published
                          </span>
                        ) : (
                          <span className="flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.2 text-[10px] font-semibold text-primary border border-primary/20">
                            <Sparkles className="h-3 w-3" />
                            Open
                          </span>
                        )}
                      </div>

                      <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
                        <span className="flex items-center gap-1">
                          <MapPin className="h-3 w-3 text-muted-foreground" />
                          Venue: <strong className="font-medium text-foreground">{s.venue ?? 'Main hall'}</strong>
                        </span>
                        <span>·</span>
                        <span>
                          Capacity: <span data-testid={`sitting-seats-${s.id}`} className="font-semibold text-foreground">{s.activeCount}</span>/{s.capacity} seats ({pctFilled}%)
                        </span>
                        <div className="w-20 bg-muted rounded-full h-1.5 overflow-hidden ml-1 inline-block align-middle">
                          <div
                            className={`h-1.5 rounded-full ${pctFilled >= 100 ? 'bg-amber-500' : 'bg-primary'}`}
                            style={{ width: `${pctFilled}%` }}
                          />
                        </div>
                      </div>
                    </div>

                    {/* Candidate Allocation Control */}
                    {!s.lockedAt && (
                      <div className="flex flex-col items-start lg:items-end gap-1">
                        <span className="text-[10px] font-medium text-muted-foreground">Allocate candidate to seat:</span>
                        <AllocateSeatForm
                          sittingId={s.id}
                          applications={applications.filter((a) => a.classAppliedId === s.classLevelId)}
                          capacity={s.capacity}
                          activeCount={s.activeCount}
                        />
                      </div>
                    )}
                  </div>

                  {/* Roll Slip Generation */}
                  <RollSlipViewer
                    sittingId={s.id}
                    className={s.className}
                    startsAt={s.startsAt}
                    venue={s.venue}
                    campusName={campusName}
                  />

                  {/* Merit & Scoring Panel */}
                  <MeritPanel sittingId={s.id} lockedAt={s.lockedAt} candidates={s.candidates} />
                </CardContent>
              </Card>
            );
          })}
        </div>
      )}
    </div>
  );
}

