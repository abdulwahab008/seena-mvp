import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { PaperForm, type ScopeUnit } from './paper-form';

type SearchParams = { class?: string; subject?: string };
const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function PapersPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const sp = await searchParams;
  const supabase = await supabaseServer();
  const [{ data: classes }, { data: subjects }] = await Promise.all([
    supabase.from('class_level').select('id, name_en').eq('is_active', true).order('ordinal'),
    supabase.from('subject').select('id, name_en').eq('is_active', true).order('name_en'),
  ]);
  const classId = classes?.find((c) => c.id === sp.class)?.id ?? classes?.[0]?.id;
  const subjectId = subjects?.find((s) => s.id === sp.subject)?.id ?? subjects?.[0]?.id;

  let units: ScopeUnit[] = [];
  let sections: { id: string; label: string }[] = [];
  if (classId && subjectId) {
    const [{ data: unitRows }, { data: cov }, { data: secRows }] = await Promise.all([
      supabase.from('syllabus_unit').select('id, sequence, title, board').eq('class_level_id', classId).eq('subject_id', subjectId).order('board').order('sequence'),
      supabase.from('syllabus_coverage').select('syllabus_unit_id, status').eq('subject_id', subjectId).in('status', ['in_progress', 'completed']),
      supabase.from('class_section').select('id, name').eq('class_level_id', classId).eq('is_active', true).order('name'),
    ]);
    const started = new Set((cov ?? []).map((c) => c.syllabus_unit_id));
    const board = unitRows?.[0]?.board;
    units = (unitRows ?? []).filter((u) => u.board === board).map((u) => ({ id: u.id, sequence: u.sequence, title: u.title, taught: started.has(u.id) }));
    sections = (secRows ?? []).map((s) => ({ id: s.id, label: `Section ${s.name}` }));
  }

  const { data: requests } = await supabase
    .from('exam_paper_request')
    .select('id, title, status, untaught_override, created_at, scope_unit_ids, subject:subject_id(name_en), class_level:class_level_id(name_en)')
    .order('created_at', { ascending: false })
    .limit(30);

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
        <h1 className="text-2xl font-semibold">Exam paper scope</h1>
        <p className="text-sm text-muted-foreground">
          FR-H09 — choose the syllabus chapters a generated paper may draw questions from. Chapters whose coverage is still not started are refused unless an Exam Controller explicitly includes them.
        </p>
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">New paper</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <form method="get" className="flex flex-wrap items-end gap-3 text-sm">
            {select('Class', classId, (classes ?? []).map((c) => ({ id: c.id, label: c.name_en })))}
            {select('Subject', subjectId, (subjects ?? []).map((s) => ({ id: s.id, label: s.name_en })))}
            <button type="submit" className="h-9 rounded-md border px-3">
              Show chapters
            </button>
          </form>
          <PaperForm key={`${classId}-${subjectId}`} units={units} sections={sections} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Requested papers</CardTitle>
        </CardHeader>
        <CardContent className="space-y-2 text-sm" data-testid="paper-list">
          {(requests ?? []).length === 0 && <p className="text-muted-foreground">No papers requested yet.</p>}
          {(requests ?? []).map((r) => (
            <div key={r.id} className="flex flex-wrap items-center justify-between gap-2 border-b pb-2" data-testid="paper-row">
              <Link href={`/exams/paper-scope/${r.id}`} className="font-medium underline-offset-2 hover:underline">
                {r.title}
              </Link>
              <span className="text-muted-foreground">
                {one(r.class_level)?.name_en} · {one(r.subject)?.name_en} · {r.scope_unit_ids.length} chapters
              </span>
              <span className="flex items-center gap-2">
                {r.untaught_override && <Badge variant="outline">override</Badge>}
                <Badge variant={r.status === 'generated' ? 'success' : r.status === 'failed' ? 'destructive' : 'outline'}>{r.status}</Badge>
              </span>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
