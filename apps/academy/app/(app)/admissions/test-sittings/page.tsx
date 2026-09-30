import { supabaseServer } from '@/lib/supabase/server';
import { SittingForm } from './sitting-form';
import { SittingList, type SittingRow, type EligibleApplication, type CandidateRow } from './sitting-list';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function TestSittingsPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: classLevels }] = await Promise.all([
    supabase.from('campus').select('id, name, code').eq('status', 'active').order('code').limit(1),
    supabase.from('class_level').select('id, name_en, code').eq('is_active', true).order('ordinal'),
  ]);
  const activeCampus = campuses?.[0];
  const campusId = activeCampus?.id;

  const { data: sessions } = campusId
    ? await supabase.from('academic_session').select('id, name').eq('is_current', true).limit(1)
    : { data: [] as { id: string; name: string }[] };
  const currentSession = sessions?.[0];
  const sessionId = currentSession?.id;

  const [{ data: sittingRows }, { data: candidateRows }, { data: appRows }, { data: meritRows }, { data: roomRows }] = await Promise.all([
    campusId && sessionId
      ? supabase
          .from('admission_test_sitting')
          .select('id, starts_at, venue, capacity, class_level_id, locked_at, class_level(name_en, code)')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .order('starts_at')
      : Promise.resolve({ data: [] as never[] }),
    campusId
      ? supabase
          .from('admission_test_candidate')
          .select('id, sitting_id, seat_no, attendance, admission_application(id, application_no, admission_enquiry(child_name, dob))')
          .is('cancelled_at', null)
      : Promise.resolve({ data: [] as never[] }),
    campusId && sessionId
      ? supabase
          .from('admission_application')
          .select('id, application_no, class_applied_id, status, admission_enquiry(child_name)')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .in('status', ['submitted', 'under_review'])
      : Promise.resolve({ data: [] as never[] }),
    campusId ? supabase.from('v_admission_merit_rank').select('sitting_id, candidate_id, pct, rnk, tie_break_basis') : Promise.resolve({ data: [] as never[] }),
    campusId
      ? supabase
          .from('room')
          .select('id, code, name, capacity, room_type, block_label')
          .eq('campus_id', campusId)
          .eq('is_active', true)
          .order('code')
      : Promise.resolve({ data: [] as never[] }),
  ]);

  const { data: scoreRows } = candidateRows?.length
    ? await supabase
        .from('admission_test_score')
        .select('candidate_id, subject_code, obtained, total')
        .in(
          'candidate_id',
          candidateRows.map((c) => c.id)
        )
    : { data: [] as never[] };

  const scoresByCandidate = new Map<string, { subjectCode: string; obtained: number; total: number }[]>();
  for (const s of scoreRows ?? []) {
    const list = scoresByCandidate.get(s.candidate_id) ?? [];
    list.push({ subjectCode: s.subject_code, obtained: s.obtained, total: s.total });
    scoresByCandidate.set(s.candidate_id, list);
  }

  const meritByCandidate = new Map<string, { pct: number; rnk: number; tieBreakBasis: string }>();
  for (const m of meritRows ?? []) {
    if (!m.candidate_id || m.pct === null || m.rnk === null || m.tie_break_basis === null) continue;
    meritByCandidate.set(m.candidate_id, { pct: m.pct, rnk: m.rnk, tieBreakBasis: m.tie_break_basis });
  }

  const candidatesBySitting = new Map<string, CandidateRow[]>();
  for (const c of candidateRows ?? []) {
    const app = one(c.admission_application);
    const row: CandidateRow = {
      id: c.id,
      seatNo: c.seat_no,
      applicationNo: app?.application_no ?? null,
      childName: one(app?.admission_enquiry ?? null)?.child_name ?? 'Unknown',
      attendance: c.attendance,
      scores: scoresByCandidate.get(c.id) ?? [],
      merit: meritByCandidate.get(c.id) ?? null,
    };
    const list = candidatesBySitting.get(c.sitting_id) ?? [];
    list.push(row);
    candidatesBySitting.set(c.sitting_id, list);
  }
  for (const list of candidatesBySitting.values()) list.sort((a, b) => a.seatNo - b.seatNo);

  const sittings: SittingRow[] = (sittingRows ?? []).map((s) => ({
    id: s.id,
    startsAt: s.starts_at,
    venue: s.venue,
    capacity: s.capacity,
    classLevelId: s.class_level_id,
    className: one(s.class_level)?.name_en ?? 'Unknown',
    activeCount: candidatesBySitting.get(s.id)?.length ?? 0,
    lockedAt: s.locked_at,
    candidates: candidatesBySitting.get(s.id) ?? [],
  }));

  const applications: EligibleApplication[] = (appRows ?? []).map((a) => ({
    id: a.id,
    applicationNo: a.application_no,
    childName: one(a.admission_enquiry)?.child_name ?? 'Unknown',
    classAppliedId: a.class_applied_id,
  }));

  const roomsList = (roomRows ?? []).map((r) => ({
    id: r.id,
    code: r.code,
    name: r.name,
    capacity: r.capacity,
    roomType: r.room_type,
    blockLabel: r.block_label,
  }));

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between border-b pb-3">
        <div>
          <div className="flex items-center gap-2.5">
            <h1 className="text-xl sm:text-2xl font-bold tracking-tight text-foreground">Admission test sittings</h1>
            {activeCampus && (
              <span className="rounded-full bg-primary/10 px-2.5 py-0.5 text-xs font-semibold text-primary">
                {activeCampus.name}
              </span>
            )}
          </div>
          <p className="text-xs sm:text-sm text-muted-foreground mt-0.5">
            Entry exam scheduling, seat assignments, score records, and merit rank lists.
          </p>
        </div>

        {currentSession && (
          <div className="flex items-center gap-1.5 rounded-lg border bg-muted/30 px-2.5 py-1 text-xs self-start sm:self-auto">
            <span className="text-muted-foreground">Session:</span>
            <span className="font-semibold text-foreground">{currentSession.name}</span>
          </div>
        )}
      </div>

      {!campusId || !sessionId ? (
        <div className="rounded-xl border border-dashed p-8 text-center">
          <p className="text-sm font-medium text-muted-foreground">No active campus or current academic session found.</p>
        </div>
      ) : (
        <>
          <SittingForm
            campusId={campusId}
            sessionId={sessionId}
            classLevels={classLevels ?? []}
            rooms={roomsList}
          />
          <SittingList
            sittings={sittings}
            applications={applications}
            campusName={activeCampus?.name ?? 'Main Campus'}
            sessionName={currentSession?.name ?? 'Current Session'}
          />
        </>
      )}
    </div>
  );
}
