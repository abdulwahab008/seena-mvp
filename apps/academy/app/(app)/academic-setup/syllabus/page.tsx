import { supabaseServer } from '@/lib/supabase/server';
import { BOARDS } from '@/lib/validation';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { CloneForm, UnitForm, UnitList, type UnitRow } from './syllabus-editor';

type SearchParams = { class?: string; subject?: string; board?: string; session?: string };

export default async function SyllabusPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const { data: campuses } = await supabase.from('campus').select('id').eq('status', 'active').order('code').limit(1);
  const campusId = campuses?.[0]?.id;
  const [{ data: classes }, { data: subjects }, { data: sessions }] = await Promise.all([
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('subject').select('id, name_en').eq('is_active', true).order('name_en'),
    supabase.from('academic_session').select('id, name, is_current').order('starts_on', { ascending: false }),
  ]);
  const classId = classes?.find((c) => c.id === sp.class)?.id ?? classes?.[0]?.id;
  const subjectId = subjects?.find((s) => s.id === sp.subject)?.id ?? subjects?.[0]?.id;
  const board = (BOARDS as readonly string[]).includes(sp.board ?? '') ? (sp.board as (typeof BOARDS)[number]) : 'FBISE';
  const sessionId = sessions?.find((s) => s.id === sp.session)?.id ?? sessions?.find((s) => s.is_current)?.id ?? sessions?.[0]?.id;

  let units: UnitRow[] = [];
  if (campusId && classId && subjectId && sessionId) {
    const { data } = await supabase
      .from('syllabus_unit')
      .select('id, sequence, title, title_ur, planned_periods, target_month, topics:syllabus_topic(id, sequence, title, planned_periods)')
      .eq('campus_id', campusId).eq('session_id', sessionId).eq('class_level_id', classId).eq('subject_id', subjectId).eq('board', board)
      .order('sequence');
    units = (data ?? []).map((u) => ({
      id: u.id, sequence: u.sequence, title: u.title, titleUr: u.title_ur, plannedPeriods: u.planned_periods, targetMonth: u.target_month,
      topics: [...(u.topics ?? [])].sort((a, b) => a.sequence - b.sequence).map((t) => ({ id: t.id, sequence: t.sequence, title: t.title, plannedPeriods: t.planned_periods })),
    }));
  }

  const select = (name: string, value: string | undefined, options: { id: string; label: string }[]) => (
    <label className="space-y-1">
      <span className="block text-muted-foreground">{name}</span>
      <select name={name.toLowerCase()} defaultValue={value} className="h-9 rounded-md border bg-background px-2">
        {options.map((o) => (
          <option key={o.id} value={o.id}>
            {o.label}
          </option>
        ))}
      </select>
    </label>
  );

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Annual syllabus</h1>
        <p className="text-sm text-muted-foreground">
          FR-H08 — chapters and topics per class, subject and board, in order. FBISE and Punjab Board versions of the same subject sit side by side; copying to a new session keeps every chapter&apos;s lineage and moves its target month a year on.
        </p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        {select('Class', classId, (classes ?? []).map((c) => ({ id: c.id, label: c.name_en })))}
        {select('Subject', subjectId, (subjects ?? []).map((s) => ({ id: s.id, label: s.name_en })))}
        {select('Board', board, BOARDS.map((b) => ({ id: b, label: b })))}
        {select('Session', sessionId, (sessions ?? []).map((s) => ({ id: s.id, label: s.name })))}
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>

      {campusId && classId && subjectId && sessionId ? (
        <>
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Chapters ({units.length})</CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <UnitList units={units} />
              <UnitForm scope={{ campusId, sessionId, classLevelId: classId, subjectId, board }} />
            </CardContent>
          </Card>
          {units.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">Copy to another session</CardTitle>
              </CardHeader>
              <CardContent>
                <CloneForm campusId={campusId} fromSessionId={sessionId} classLevelId={classId} subjectId={subjectId} sessions={(sessions ?? []).filter((s) => s.id !== sessionId).map((s) => ({ id: s.id, name: s.name }))} />
              </CardContent>
            </Card>
          )}
        </>
      ) : (
        <p className="text-sm text-muted-foreground">Set up a campus, a session, a class and a subject first.</p>
      )}
    </div>
  );
}
