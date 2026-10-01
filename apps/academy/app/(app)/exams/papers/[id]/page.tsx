import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

const one = <T,>(v: T | T[] | null): T | null => (Array.isArray(v) ? (v[0] ?? null) : v);

export default async function PaperDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: paper } = await supabase
    .from('exam_paper_request')
    .select('id, title, status, error, untaught_override, override_at, scope_unit_ids, subject:subject_id(name_en), class_level:class_level_id(name_en)')
    .eq('id', id)
    .maybeSingle();
  if (!paper) notFound();

  const [{ data: questions }, { data: scope }] = await Promise.all([
    supabase
      .from('exam_paper_question')
      .select('id, sequence, question_text, marks, source_chapter, unit:syllabus_unit_id(sequence, title), topic:syllabus_topic_id(title)')
      .eq('paper_request_id', id)
      .order('sequence'),
    supabase.from('syllabus_unit').select('id, sequence, title').in('id', paper.scope_unit_ids).order('sequence'),
  ]);

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <Link href="/exams/papers" className="text-sm text-muted-foreground hover:underline">
          ← All papers
        </Link>
        <h1 className="text-2xl font-semibold">{paper.title}</h1>
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          {one(paper.class_level)?.name_en} · {one(paper.subject)?.name_en}
          <Badge variant={paper.status === 'generated' ? 'success' : 'outline'}>{paper.status}</Badge>
          {paper.untaught_override && <Badge variant="outline">includes untaught chapters (override confirmed)</Badge>}
        </p>
        {paper.error && <p className="text-sm text-destructive">{paper.error}</p>}
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Chapters in scope</CardTitle>
        </CardHeader>
        <CardContent className="text-sm" data-testid="paper-scope">
          {(scope ?? []).map((u) => `${u.sequence}. ${u.title}`).join(' · ')}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">Questions</CardTitle>
        </CardHeader>
        <CardContent className="space-y-3 text-sm" data-testid="paper-questions">
          {(questions ?? []).length === 0 && <p className="text-muted-foreground">{paper.status === 'generated' ? 'No questions.' : 'The paper is waiting to be generated.'}</p>}
          {(questions ?? []).map((q) => (
            <div key={q.id} className="border-b pb-2" data-testid="paper-question">
              <p>
                <span className="font-medium">Q{q.sequence}.</span> {q.question_text} <span className="text-muted-foreground">[{q.marks}]</span>
              </p>
              <p className="text-xs text-muted-foreground" data-testid="question-source">
                Source: chapter {one(q.unit)?.sequence}. {one(q.unit)?.title}
                {one(q.topic) ? ` · topic: ${one(q.topic)?.title}` : ''}
                {q.source_chapter ? ` · ${q.source_chapter}` : ''}
              </p>
            </div>
          ))}
        </CardContent>
      </Card>
    </div>
  );
}
