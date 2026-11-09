import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { getCurrentActor } from '@/lib/hr/current-role';
import { pickActiveCampus } from '@/lib/campus-context';
import { formatDateTimePk } from '@/lib/dates';
import { formatPct } from '@/lib/format-money';
import { PageHeader } from '@/components/ui/page-header';
import { EmptyState } from '@/components/ui/empty-state';
import { Breakdown, KpiGrid } from '@/components/module-dashboard';

export const dynamic = 'force-dynamic';

const ROLES = ['super_admin', 'owner', 'principal', 'vice_principal', 'exam_controller', 'head_of_department'];
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function ExamsDashboardPage() {
  const actor = await getCurrentActor();
  if (!actor || !ROLES.includes(actor.role)) notFound();
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id, name').eq('status', 'active').order('code');
  const campus = await pickActiveCampus(campuses);
  if (!campus) return <EmptyState title="No campus selected" description="Choose a campus from the switcher at the top." />;

  const now = new Date().toISOString();
  const [{ data: activeTerms }, { data: lastLocked }, lockedTerms, upcomingCount, { data: upcoming }] = await Promise.all([
    supabase.from('exam_term').select('id, name, session_id').eq('campus_id', campus.id).eq('status', 'active').order('sequence'),
    supabase.from('exam_term').select('id, name').eq('campus_id', campus.id).eq('status', 'locked').order('locked_at', { ascending: false, nullsFirst: false }).limit(1).maybeSingle(),
    supabase.from('exam_term').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).eq('status', 'locked'),
    supabase.from('datesheet_slot').select('id', { count: 'exact', head: true }).eq('campus_id', campus.id).gte('start_at', now),
    supabase
      .from('datesheet_slot')
      .select('id, start_at, exam_subject:exam_subject_id(class_subject:class_subject_id(class_level:class_level_id(name_en), subject:subject_id(name_en)))')
      .eq('campus_id', campus.id)
      .gte('start_at', now)
      .order('start_at')
      .limit(6),
  ]);

  const termIds = (activeTerms ?? []).map((t) => t.id);
  const sessionIds = [...new Set((activeTerms ?? []).map((t) => t.session_id))];
  const [{ data: examSubjects }, { data: sections }, { data: locks }, passed, graded] = await Promise.all([
    termIds.length ? supabase.from('exam_subject').select('id, exam_term_id, class_subject:class_subject_id(class_level_id)').in('exam_term_id', termIds) : Promise.resolve({ data: [] }),
    sessionIds.length ? supabase.from('class_section').select('id, session_id, class_level_id').eq('campus_id', campus.id).eq('is_active', true).in('session_id', sessionIds) : Promise.resolve({ data: [] }),
    termIds.length ? supabase.from('mark_lock').select('exam_term_id').in('exam_term_id', termIds).eq('unlock_state', 'locked') : Promise.resolve({ data: [] }),
    lastLocked ? supabase.from('subject_result').select('id', { count: 'exact', head: true }).eq('exam_term_id', lastLocked.id).eq('is_pass', true) : Promise.resolve({ count: 0 }),
    lastLocked ? supabase.from('subject_result').select('id', { count: 'exact', head: true }).eq('exam_term_id', lastLocked.id).not('is_pass', 'is', null) : Promise.resolve({ count: 0 }),
  ]);

  const progress = (activeTerms ?? []).map((t) => {
    const sheets = (examSubjects ?? [])
      .filter((s) => s.exam_term_id === t.id)
      .reduce((sum, s) => sum + (sections ?? []).filter((c) => c.session_id === t.session_id && c.class_level_id === one(s.class_subject)?.class_level_id).length, 0);
    const locked = (locks ?? []).filter((l) => l.exam_term_id === t.id).length;
    return { term: t, sheets, locked };
  });
  const pending = progress.reduce((sum, p) => sum + Math.max(0, p.sheets - p.locked), 0);
  const passRate = (graded.count ?? 0) > 0 ? ((passed.count ?? 0) * 100) / (graded.count ?? 1) : null;
  const progressRows = progress.map((p) => ({
    key: p.term.id,
    label: p.term.name,
    value: p.sheets ? (p.locked * 100) / p.sheets : 0,
    display: `${p.locked} of ${p.sheets} locked`,
  }));

  return (
    <>
      <PageHeader title="Exams dashboard" description={`Upcoming papers, mark sheets still open and the last term's results at ${campus.name}.`} />
      <KpiGrid
        prefix="exams"
        kpis={[
          { id: 'active-terms', label: 'Terms in progress', value: termIds.length },
          { id: 'upcoming', label: 'Upcoming papers', value: upcomingCount.count ?? 0 },
          { id: 'marks-pending', label: 'Mark sheets not yet locked', value: pending },
          { id: 'locked-terms', label: 'Terms with results locked', value: lockedTerms.count ?? 0 },
          { id: 'pass-rate', label: lastLocked ? `Subject pass rate, ${lastLocked.name}` : 'Subject pass rate, last term', value: formatPct(passRate) },
        ]}
      />
      <div className="mt-6 grid gap-6 lg:grid-cols-2">
        <Breakdown title="Mark entry progress by term" rows={progressRows} empty="No term is in progress." bars />
        <section className="space-y-2">
          <h2 className="font-medium">Next papers</h2>
          {(upcoming ?? []).length === 0 ? (
            <p className="text-sm text-muted-foreground">No papers scheduled.</p>
          ) : (
            (upcoming ?? []).map((s) => {
              const cs = one(one(s.exam_subject)?.class_subject ?? null);
              return (
                <p key={s.id} className="flex justify-between gap-2 text-sm" data-testid="exams-upcoming">
                  <span>
                    {one(cs?.class_level ?? null)?.name_en ?? 'Class'} · {one(cs?.subject ?? null)?.name_en ?? 'Subject'}
                  </span>
                  <span className="text-muted-foreground">{formatDateTimePk(s.start_at)}</span>
                </p>
              );
            })
          )}
        </section>
      </div>
    </>
  );
}
