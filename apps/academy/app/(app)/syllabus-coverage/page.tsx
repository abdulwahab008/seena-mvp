import { supabaseServer } from '@/lib/supabase/server';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CoverageRow, type CoverageUnit } from './coverage-row';

type SearchParams = { assignment?: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function SyllabusCoveragePage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // A teacher sees their own section-subjects; a Principal (who teaches none) sees every one on the campus.
  const select = 'section_id, subject_id, class_section:section_id(name, class_level_id, class_level(name_en)), subject:subject_id(name_en)';
  const { data: mine } = await supabase.from('section_subject_teacher').select(select).eq('staff_id', user!.id);
  const { data: all } = mine && mine.length > 0 ? { data: mine } : await supabase.from('section_subject_teacher').select(select);
  const assignments = [...new Map((all ?? []).map((a) => [`${a.section_id}:${a.subject_id}`, a])).values()].map((a) => {
    const section = one(a.class_section);
    const level = section ? one(section.class_level) : null;
    return { key: `${a.section_id}:${a.subject_id}`, sectionId: a.section_id, subjectId: a.subject_id, classLevelId: section?.class_level_id ?? null, label: `${level?.name_en ?? ''} ${section?.name ?? ''} · ${one(a.subject)?.name_en ?? ''}`.trim() };
  });
  const chosen = assignments.find((a) => a.key === sp.assignment) ?? assignments[0];

  let units: CoverageUnit[] = [];
  let pct: number | null = null;
  let history: { id: string; at: string; unit: string; change: string; who: string }[] = [];
  if (chosen?.classLevelId) {
    const [{ data: unitRows }, { data: cov }, { data: pctData }] = await Promise.all([
      supabase.from('syllabus_unit').select('id, sequence, title, board, planned_periods').eq('class_level_id', chosen.classLevelId).eq('subject_id', chosen.subjectId).order('board').order('sequence'),
      supabase.from('syllabus_coverage').select('id, syllabus_unit_id, status, started_on, completed_on, periods_used, start_inferred').eq('section_id', chosen.sectionId).eq('subject_id', chosen.subjectId),
      supabase.rpc('coverage_pct', { p_section_id: chosen.sectionId, p_subject_id: chosen.subjectId }),
    ]);
    pct = pctData as number | null;
    const covBy = new Map((cov ?? []).map((c) => [c.syllabus_unit_id, c]));
    // The section follows one board's syllabus: the one it already has coverage for, else the first.
    const board = (unitRows ?? []).find((u) => covBy.has(u.id))?.board ?? unitRows?.[0]?.board;
    units = (unitRows ?? [])
      .filter((u) => u.board === board)
      .map((u) => {
        const c = covBy.get(u.id);
        return { unitId: u.id, sequence: u.sequence, title: u.title, plannedPeriods: u.planned_periods, status: c?.status ?? 'not_started', startedOn: c?.started_on ?? null, completedOn: c?.completed_on ?? null, periodsUsed: c?.periods_used ?? 0, inferred: c?.start_inferred ?? false };
      });
    const covIds = (cov ?? []).map((c) => c.id);
    if (covIds.length > 0) {
      const { data: hist } = await supabase
        .from('syllabus_coverage_history')
        .select('id, old_status, new_status, changed_at, changed_by, coverage_id')
        .in('coverage_id', covIds)
        .order('changed_at', { ascending: false })
        .limit(15);
      const who = new Map<string, string>();
      const ids = [...new Set((hist ?? []).map((h) => h.changed_by).filter((v): v is string => !!v))];
      if (ids.length > 0) {
        const { data: users } = await supabase.from('app_user').select('user_id, full_name').in('user_id', ids);
        for (const u of users ?? []) who.set(u.user_id, u.full_name);
      }
      const unitOf = new Map((cov ?? []).map((c) => [c.id, units.find((u) => u.unitId === c.syllabus_unit_id)?.title ?? 'Unit']));
      history = (hist ?? []).map((h) => ({
        id: h.id,
        at: new Date(h.changed_at).toLocaleString('en-GB', { timeZone: 'Asia/Karachi' }),
        unit: unitOf.get(h.coverage_id) ?? 'Unit',
        change: `${(h.old_status ?? 'new').replace('_', ' ')} → ${h.new_status.replace('_', ' ')}`,
        who: h.changed_by ? (who.get(h.changed_by) ?? 'Staff') : 'System',
      }));
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Syllabus coverage</h1>
        <p className="text-sm text-muted-foreground">FR-H11 — mark each chapter as not started, in progress or completed for your section. Coverage is weighted by planned periods, so a 14-period chapter counts for more than a 2-period one.</p>
      </div>

      {assignments.length === 0 ? (
        <p className="text-sm text-muted-foreground">No section and subject has been assigned to you yet.</p>
      ) : (
        <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
          <label className="space-y-1">
            <span className="block text-muted-foreground">Class and subject</span>
            <select name="assignment" defaultValue={chosen?.key} className="h-9 rounded-md border bg-background px-2">
              {assignments.map((a) => (
                <option key={a.key} value={a.key}>
                  {a.label}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="h-9 rounded-md border px-3">
            Show
          </button>
        </form>
      )}

      {chosen && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              {chosen.label} — <span data-testid="coverage-pct">{pct === null ? 'no syllabus' : `${pct.toFixed(2)}% covered`}</span>
            </CardTitle>
          </CardHeader>
          <CardContent>
            {units.length === 0 ? (
              <p className="text-sm text-muted-foreground">No syllabus has been defined for this class and subject yet.</p>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-left text-sm">
                  <thead>
                    <tr className="border-b text-muted-foreground">
                      <th className="py-1">Chapter</th>
                      <th>Status</th>
                      <th>Started</th>
                      <th>Completed</th>
                      <th>Periods used</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {units.map((u) => (
                      <CoverageRow key={`${u.unitId}-${u.status}-${u.completedOn}-${u.startedOn}`} sectionId={chosen.sectionId} subjectId={chosen.subjectId} unit={u} />
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </CardContent>
        </Card>
      )}

      {history.length > 0 && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Recent changes</CardTitle>
          </CardHeader>
          <CardContent className="space-y-1 text-sm" data-testid="coverage-history">
            {history.map((h) => (
              <p key={h.id} className="text-muted-foreground">
                {h.at} · {h.unit}: {h.change} · {h.who}
              </p>
            ))}
          </CardContent>
        </Card>
      )}
    </div>
  );
}
