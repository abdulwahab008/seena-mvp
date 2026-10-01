import Link from 'next/link';
import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

/**
 * FR-I05. One generated paper: its sections and questions, with the provenance
 * the worker returned (chapter, topic tag, SLO code, source pages).
 */
type Section = { no: number; name: string; type: string; count: number; marks_each: number };

export default async function PaperDetailPage({ params }: { params: Promise<{ paperId: string }> }) {
  const { paperId } = await params;
  const supabase = await supabaseServer();
  const { data: paper } = await supabase.from('exam_paper').select('id, set_code, status, title, total_marks, pattern_snapshot, created_at').eq('id', paperId).maybeSingle();
  if (!paper) notFound();
  const { data: questions } = await supabase
    .from('exam_paper_item')
    .select('id, section_no, question_no, question_type, marks, question_text, options, answer, chapter, topic_tag, slo_code, source_pages')
    .eq('paper_id', paperId)
    .order('section_no')
    .order('question_no');
  const sections = ((paper.pattern_snapshot as { sections?: Section[] } | null)?.sections ?? []) as Section[];

  return (
    <div className="space-y-6">
      <div className="space-y-1">
        <Link className="text-sm underline" href="/exams/papers">
          Back to papers
        </Link>
        <h1 className="text-2xl font-semibold">{paper.title}</h1>
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          Set {paper.set_code} · {paper.total_marks} marks <Badge variant={paper.status === 'published' ? 'success' : 'outline'}>{paper.status}</Badge>
        </p>
      </div>

      {sections.map((s) => (
        <Card key={s.no}>
          <CardHeader>
            <CardTitle className="text-base">
              {s.name} — {s.count} × {s.marks_each} marks
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm" data-testid={`section-${s.no}`}>
            {(questions ?? [])
              .filter((q) => q.section_no === s.no)
              .map((q) => {
                const options = Array.isArray(q.options) ? (q.options as string[]) : [];
                const pages = Array.isArray(q.source_pages) ? (q.source_pages as number[]) : [];
                return (
                  <div key={q.id} className="space-y-1 border-b pb-2" data-testid="paper-question">
                    <p>
                      <span className="font-medium">Q{q.question_no}.</span> {q.question_text} <span className="text-muted-foreground">[{q.marks}]</span>
                    </p>
                    {options.length > 0 && (
                      <ul className="list-disc pl-6 text-muted-foreground">
                        {options.map((o, i) => (
                          <li key={i}>{o}</li>
                        ))}
                      </ul>
                    )}
                    <p className="text-xs text-muted-foreground">
                      {[q.chapter, q.topic_tag, q.slo_code, pages.length > 0 ? `pp. ${pages.join(', ')}` : null, q.answer ? `answer: ${q.answer}` : null].filter(Boolean).join(' · ')}
                    </p>
                  </div>
                );
              })}
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
