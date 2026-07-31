import { supabaseServer } from '@/lib/supabase/server';
import { SittingForm } from './sitting-form';
import { SittingList, type SittingRow, type EligibleApplication } from './sitting-list';

function one<T>(v: T | T[] | null): T | null {
  return Array.isArray(v) ? (v[0] ?? null) : v;
}

export default async function TestSittingsPage() {
  const supabase = await supabaseServer();

  const [{ data: campuses }, { data: classLevels }] = await Promise.all([
    supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1),
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
  ]);
  const campusId = campuses?.[0]?.id;

  const { data: sessions } = campusId
    ? await supabase.from('academic_session').select('id').eq('is_current', true).limit(1)
    : { data: [] as { id: string }[] };
  const sessionId = sessions?.[0]?.id;

  const [{ data: sittingRows }, { data: candidateRows }, { data: appRows }] = await Promise.all([
    campusId && sessionId
      ? supabase
          .from('admission_test_sitting')
          .select('id, starts_at, venue, capacity, class_level_id, class_level(name_en)')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .order('starts_at')
      : Promise.resolve({ data: [] as never[] }),
    campusId ? supabase.from('admission_test_candidate').select('sitting_id').is('cancelled_at', null) : Promise.resolve({ data: [] as never[] }),
    campusId && sessionId
      ? supabase
          .from('admission_application')
          .select('id, application_no, class_applied_id, status, admission_enquiry(child_name)')
          .eq('campus_id', campusId)
          .eq('session_id', sessionId)
          .in('status', ['submitted', 'under_review'])
      : Promise.resolve({ data: [] as never[] }),
  ]);

  const activeCountBySitting = new Map<string, number>();
  for (const c of candidateRows ?? []) {
    activeCountBySitting.set(c.sitting_id, (activeCountBySitting.get(c.sitting_id) ?? 0) + 1);
  }

  const sittings: SittingRow[] = (sittingRows ?? []).map((s) => ({
    id: s.id,
    startsAt: s.starts_at,
    venue: s.venue,
    capacity: s.capacity,
    classLevelId: s.class_level_id,
    className: one(s.class_level)?.name_en ?? 'Unknown',
    activeCount: activeCountBySitting.get(s.id) ?? 0,
  }));

  const applications: EligibleApplication[] = (appRows ?? []).map((a) => ({
    id: a.id,
    applicationNo: a.application_no,
    childName: one(a.admission_enquiry)?.child_name ?? 'Unknown',
    classAppliedId: a.class_applied_id,
  }));

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Admission test sittings</h1>
        <p className="text-sm text-muted-foreground">FR-B11 — schedule test sittings, allocate conflict-free seats, and view the roll slip.</p>
      </div>
      {!campusId || !sessionId ? (
        <p className="text-sm text-muted-foreground">No active campus or current session found.</p>
      ) : (
        <>
          <SittingForm campusId={campusId} sessionId={sessionId} classLevels={classLevels ?? []} />
          <SittingList sittings={sittings} applications={applications} />
        </>
      )}
    </div>
  );
}
