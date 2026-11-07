import { notFound } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase/server';
import { one } from '@/lib/hr/current-role';
import { formatDateTimePk } from '@/lib/dates';
import { PageHeader } from '@/components/ui/page-header';
import { Badge } from '@/components/ui/badge';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { PublishButton, QuestionForm } from '../quiz-forms';

export const dynamic = 'force-dynamic';

export default async function QuizPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const supabase = await supabaseServer();
  const { data: quiz } = await supabase.from('quiz').select('id, title, opens_at, closes_at, duration_min, status').eq('id', id).maybeSingle();
  if (!quiz) notFound();
  const [{ data: questions }, { data: attempts }] = await Promise.all([
    supabase.from('quiz_question').select('id, position, prompt, options, correct_index, marks').eq('quiz_id', id).order('position'),
    supabase.from('quiz_attempt').select('id, submitted_at, score, max_score, student:student_id(name_en, gr_number)').eq('quiz_id', id).order('score', { ascending: false }),
  ]);
  const total = (questions ?? []).reduce((s, q) => s + q.marks, 0);

  return (
    <>
      <PageHeader
        title={quiz.title}
        description={`Open ${formatDateTimePk(quiz.opens_at)} to ${formatDateTimePk(quiz.closes_at)} · ${quiz.duration_min} minutes · ${total} marks`}
        actions={quiz.status === 'draft' ? <PublishButton quizId={quiz.id} /> : <Badge variant="success" data-testid="quiz-status">published</Badge>}
      />
      <div className="space-y-4">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">Questions ({(questions ?? []).length})</CardTitle>
          </CardHeader>
          <CardContent className="space-y-3 text-sm">
            {(questions ?? []).length === 0 && <p className="text-muted-foreground">No questions yet.</p>}
            {(questions ?? []).map((q) => (
              <div key={q.id} className="border-b pb-2" data-testid="quiz-question">
                <p className="font-medium">
                  {q.position}. {q.prompt} <span className="text-muted-foreground">({q.marks} marks)</span>
                </p>
                <ol className="ml-5 list-[lower-alpha]">
                  {q.options.map((o, i) => (
                    <li key={i} className={i === q.correct_index ? 'font-medium text-success' : ''}>
                      {o}
                      {i === q.correct_index ? ' ✓' : ''}
                    </li>
                  ))}
                </ol>
              </div>
            ))}
          </CardContent>
        </Card>
        {quiz.status === 'draft' && <QuestionForm quizId={quiz.id} />}
        {quiz.status === 'published' && (
          <Card>
            <CardHeader>
              <CardTitle className="text-base">Results</CardTitle>
            </CardHeader>
            <CardContent>
              {(attempts ?? []).length === 0 ? (
                <p className="text-sm text-muted-foreground">No attempts yet.</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Student</TableHead>
                      <TableHead>Submitted</TableHead>
                      <TableHead className="text-right">Score</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {(attempts ?? []).map((a) => (
                      <TableRow key={a.id} data-testid="quiz-result">
                        <TableCell>
                          {one(a.student)?.name_en} <span className="text-xs text-muted-foreground">{one(a.student)?.gr_number}</span>
                        </TableCell>
                        <TableCell>{a.submitted_at ? formatDateTimePk(a.submitted_at) : 'In progress'}</TableCell>
                        <TableCell className="text-right">{a.submitted_at ? `${a.score} / ${a.max_score}` : '—'}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        )}
      </div>
    </>
  );
}
