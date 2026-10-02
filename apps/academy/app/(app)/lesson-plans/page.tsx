import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PlanForm, StatusButtons, type TopicGroup } from './plan-forms';

type SearchParams = { week?: string; assignment?: string; teacher?: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

function mondayOf(iso: string): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}
const todayIso = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Karachi' });

export default async function LessonPlansPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const week = mondayOf(/^\d{4}-\d{2}-\d{2}$/.test(sp.week ?? '') ? (sp.week as string) : todayIso());
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: mine } = await supabase
    .from('section_subject_teacher')
    .select('section_id, subject_id, class_section:section_id(name, class_level_id, class_level(name_en)), subject:subject_id(name_en)')
    .eq('staff_id', user!.id);
  const assignments = (mine ?? []).map((a) => {
    const section = one(a.class_section);
    const level = section ? one(section.class_level) : null;
    return { key: `${a.section_id}:${a.subject_id}`, sectionId: a.section_id, subjectId: a.subject_id, classLevelId: section?.class_level_id ?? null, label: `${level?.name_en ?? ''} ${section?.name ?? ''} · ${one(a.subject)?.name_en ?? ''}`.trim() };
  });
  const chosen = assignments.find((a) => a.key === sp.assignment) ?? assignments[0];

  let groups: TopicGroup[] = [];
  let existing: { id: string; status: string } | null = null;
  if (chosen?.classLevelId) {
    const [{ data: units }, { data: plan }] = await Promise.all([
      supabase
        .from('syllabus_unit')
        .select('id, sequence, title, board, topics:syllabus_topic(id, sequence, title)')
        .eq('class_level_id', chosen.classLevelId)
        .eq('subject_id', chosen.subjectId)
        .order('board')
        .order('sequence'),
      supabase.from('lesson_plan').select('id, status').eq('section_id', chosen.sectionId).eq('subject_id', chosen.subjectId).eq('week_start_date', week).maybeSingle(),
    ]);
    groups = (units ?? []).map((u) => ({ unitId: u.id, unitTitle: `${u.board} · ${u.sequence}. ${u.title}`, topics: [...(u.topics ?? [])].sort((a, b) => a.sequence - b.sequence).map((t) => ({ id: t.id, title: t.title })) }));
    existing = plan;
  }

  const { data: plans } = await supabase
    .from('lesson_plan')
    .select('id, week_start_date, objectives, status, completion_date, teacher_id, class_section:section_id(name, class_level(name_en)), subject:subject_id(name_en), teacher:teacher_id(full_name), topics:lesson_plan_topic(syllabus_topic:syllabus_topic_id(title))')
    .eq('week_start_date', week)
    .order('created_at');
  const teachers = [...new Map((plans ?? []).map((p) => [p.teacher_id, one(p.teacher)?.full_name ?? 'Teacher'])).entries()];
  const shown = (plans ?? []).filter((p) => !sp.teacher || p.teacher_id === sp.teacher);

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Lesson plans</h1>
        <p className="text-sm text-muted-foreground">FR-H10 — plan which syllabus topics you will cover each week. One plan per section, subject and week; the week always starts on Monday. Planning is optional.</p>
      </div>

      <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
        <label className="space-y-1">
          <span className="block text-muted-foreground">Week of</span>
          <input type="date" name="week" defaultValue={week} className="h-9 rounded-md border bg-background px-2" />
        </label>
        {assignments.length > 0 && (
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
        )}
        {teachers.length > 1 && (
          <label className="space-y-1">
            <span className="block text-muted-foreground">Teacher</span>
            <select name="teacher" defaultValue={sp.teacher ?? ''} className="h-9 rounded-md border bg-background px-2">
              <option value="">All teachers</option>
              {teachers.map(([id, name]) => (
                <option key={id} value={id}>
                  {name}
                </option>
              ))}
            </select>
          </label>
        )}
        <button type="submit" className="h-9 rounded-md border px-3">
          Show
        </button>
      </form>

      {chosen && (
        <Card>
          <CardHeader>
            <CardTitle className="text-base">
              Plan for {chosen.label}, week of {week}
            </CardTitle>
          </CardHeader>
          <CardContent>
            {existing ? <p className="text-sm text-muted-foreground">You already planned this week ({existing.status.replace('_', ' ')}).</p> : <PlanForm key={`${chosen.key}-${week}`} sectionId={chosen.sectionId} subjectId={chosen.subjectId} weekStart={week} groups={groups} />}
          </CardContent>
        </Card>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Plans for the week of {week}</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="plan-list">
          {shown.length === 0 && <p className="text-muted-foreground">No plans for this week.</p>}
          {shown.map((p) => {
            const section = one(p.class_section);
            const level = section ? one(section.class_level) : null;
            const mineP = p.teacher_id === user!.id;
            return (
              <div key={p.id} className="space-y-1 border-b pb-3" data-testid="plan-row">
                <div className="flex items-center justify-between gap-2">
                  <span className="font-medium">
                    {level?.name_en} {section?.name} · {one(p.subject)?.name_en} · {one(p.teacher)?.full_name}
                  </span>
                  <span className="flex items-center gap-2">
                    <Badge variant={p.status === 'completed' ? 'success' : 'outline'}>{p.status.replace('_', ' ')}</Badge>
                    {mineP && <StatusButtons planId={p.id} status={p.status} />}
                  </span>
                </div>
                {p.objectives && <p className="text-muted-foreground">{p.objectives}</p>}
                <p className="text-xs text-muted-foreground">{(p.topics ?? []).map((t) => one(t.syllabus_topic)?.title).filter(Boolean).join(', ') || 'No topics linked'}</p>
                {p.completion_date && <p className="text-xs text-muted-foreground">Completed on {p.completion_date}</p>}
              </div>
            );
          })}
        </CardContent>
      </Card>
    </div>
  );
}
