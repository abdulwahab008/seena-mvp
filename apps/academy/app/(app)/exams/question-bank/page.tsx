import Link from 'next/link';
import { supabaseServer } from '@/lib/supabase/server';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { EmptyState } from '@/components/ui/empty-state';
import { PageHeader } from '@/components/ui/page-header';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { ActiveToggle, BankQuestionForm } from './bank-forms';

const TYPE_LABEL: Record<string, string> = { mcq: 'MCQ', short: 'Short', long: 'Long' };

export default async function QuestionBankPage({ searchParams }: { searchParams: Promise<{ cs?: string }> }) {
  const { cs } = await searchParams;
  const supabase = await supabaseServer();
  const { data: subjects } = await supabase.rpc('my_bank_class_subjects');
  const options = subjects ?? [];
  const selected = options.find((o) => o.class_subject_id === cs) ?? options[0];

  const header = (
    <PageHeader
      title="Question bank"
      description={
        <>
          Type in questions for the subjects you teach. <Link href="/exams/papers" className="underline">Question Papers</Link> builds Set A and Set B from these, matching the board pattern, and published papers add their questions here too.
        </>
      }
    />
  );
  if (!selected) {
    return (
      <div>
        {header}
        <EmptyState title="No subjects to add questions to" description="You can add questions for the subjects you are assigned to teach this session. Ask the principal to assign your subjects." />
      </div>
    );
  }

  const { data: target } = await supabase.from('class_subject').select('subject_id, class_level_id').eq('id', selected.class_subject_id).single();
  const { data: items } = target
    ? await supabase
        .from('question_bank_item')
        .select('id, chapter, question_type, marks, question_text, options, answer, difficulty, is_active')
        .eq('subject_id', target.subject_id)
        .eq('class_level_id', target.class_level_id)
        .order('chapter')
        .order('question_type')
        .order('created_at')
        .limit(500)
    : { data: [] };
  const questions = items ?? [];
  const counts = new Map<string, number>();
  for (const q of questions) {
    if (!q.is_active) continue;
    const key = `${q.chapter ?? 'No chapter'} · ${TYPE_LABEL[q.question_type]} ${q.marks}m`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }

  return (
    <div className="space-y-6">
      {header}
      <form className="flex flex-wrap items-end gap-2" method="get">
        <div className="space-y-1">
          <label htmlFor="bankCs" className="text-sm font-medium">
            Class and subject
          </label>
          <select id="bankCs" name="cs" defaultValue={selected.class_subject_id} className="h-10 min-w-64 rounded-md border bg-background px-2 text-sm">
            {options.map((o) => (
              <option key={o.class_subject_id} value={o.class_subject_id}>
                {o.class_name} · {o.subject_name}
              </option>
            ))}
          </select>
        </div>
        <Button type="submit" variant="outline">
          Show
        </Button>
      </form>

      <Card>
        <CardHeader>
          <CardTitle>
            Add a question: {selected.class_name} · {selected.subject_name}
          </CardTitle>
        </CardHeader>
        <CardContent>
          <BankQuestionForm key={selected.class_subject_id} classSubjectId={selected.class_subject_id} />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle>In the bank ({questions.filter((q) => q.is_active).length} active)</CardTitle>
          {counts.size > 0 && (
            <div className="flex flex-wrap gap-2 pt-2">
              {[...counts].map(([k, n]) => (
                <Badge key={k} variant="outline">
                  {k}: {n}
                </Badge>
              ))}
            </div>
          )}
        </CardHeader>
        <CardContent>
          {questions.length === 0 ? (
            <p className="text-sm text-muted-foreground">No questions yet for this class and subject.</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Chapter</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>Marks</TableHead>
                  <TableHead>Question</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {questions.map((q) => {
                  const opts = Array.isArray(q.options) ? (q.options as string[]) : [];
                  return (
                    <TableRow key={q.id} className={q.is_active ? undefined : 'opacity-50'}>
                      <TableCell>{q.chapter}</TableCell>
                      <TableCell>{TYPE_LABEL[q.question_type]}</TableCell>
                      <TableCell>{q.marks}</TableCell>
                      <TableCell className="max-w-xl whitespace-pre-line">
                        {q.question_text}
                        {opts.length > 0 && (
                          <span className="mt-1 block text-xs text-muted-foreground">
                            {opts.map((o, i) => `${'ABCD'[i]}) ${o}`).join('   ')}
                            {q.answer ? ` · Answer: ${q.answer}` : ''}
                          </span>
                        )}
                        {!q.is_active && <span className="mt-1 block text-xs">Retired: not used in new sets</span>}
                      </TableCell>
                      <TableCell className="text-right">
                        <ActiveToggle id={q.id} active={q.is_active} />
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
