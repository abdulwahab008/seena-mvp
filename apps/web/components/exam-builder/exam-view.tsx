'use client';

import { useState } from 'react';
import { toast } from 'sonner';
import type { Exam } from '@seena/shared';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Textarea } from '@/components/ui/textarea';
import { SubmissionsPanel } from './submissions-panel';

type Props = {
  examId: string;
  initialPayload: Exam;
  title: string;
};

export function ExamView({ examId, initialPayload, title }: Props) {
  const [exam, setExam] = useState<Exam>(initialPayload);
  const [busy, setBusy] = useState<string | null>(null);
  const [versions, setVersions] = useState(1);

  async function regenerate(sectionIndex: number, questionIndex: number) {
    const key = `r-${sectionIndex}-${questionIndex}`;
    setBusy(key);
    try {
      const res = await fetch(`/api/exams/${examId}/regenerate-question`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ examId, sectionIndex, questionIndex }),
      });
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      // Functional updater: apply against whatever the exam looks like when
      // this resolves, not the snapshot from when the request was fired —
      // otherwise any edit made while this LLM call was in flight (which can
      // take several seconds) gets silently overwritten.
      setExam((prev) => {
        const next = structuredClone(prev);
        next.sections[sectionIndex]!.questions[questionIndex] = data.question;
        return next;
      });
      toast.success('Question regenerated.');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function saveToBank(sectionIndex: number, questionIndex: number) {
    const key = `bank-${sectionIndex}-${questionIndex}`;
    setBusy(key);
    try {
      const question = exam.sections[sectionIndex]!.questions[questionIndex];
      const res = await fetch('/api/bank', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ examId, question }),
      });
      if (!res.ok) throw new Error(await res.text());
      toast.success('Saved to question bank.');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function savePayload(next: Exam) {
    setExam(next);
    setBusy('save');
    try {
      const res = await fetch(`/api/exams/${examId}`, {
        method: 'PATCH',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ payload: next }),
      });
      if (!res.ok) throw new Error(await res.text());
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  async function exportPdf() {
    setBusy('export');
    try {
      const res = await fetch(`/api/exams/${examId}/export`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ format: 'pdf', versions }),
      });
      if (!res.ok) throw new Error(await res.text());
      const data = await res.json();
      window.open(data.url, '_blank');
    } catch (e) {
      toast.error((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  let questionCounter = 0;

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-semibold">{title}</h1>
          <p className="text-sm text-muted-foreground">
            {exam.pattern} · {exam.total_marks} marks
          </p>
        </div>
        <div className="flex items-center gap-2">
          <select
            value={versions}
            onChange={(e) => setVersions(Number(e.target.value))}
            className="h-9 rounded-md border border-input bg-background px-2 text-sm"
            aria-label="Number of shuffled versions"
            title="Shuffled anti-leak versions"
          >
            <option value={1}>1 version</option>
            <option value={2}>2 versions</option>
            <option value={3}>3 versions</option>
            <option value={4}>4 versions</option>
          </select>
          <Button onClick={exportPdf} disabled={busy === 'export'}>
            {busy === 'export'
              ? 'Rendering…'
              : versions > 1
                ? `Export ${versions} versions`
                : 'Export PDF'}
          </Button>
        </div>
      </div>

      {exam.sections.map((section, si) => (
        <Card key={si}>
          <CardHeader>
            <CardTitle>{section.title}</CardTitle>
            <p className="text-sm text-muted-foreground">{section.instructions}</p>
          </CardHeader>
          <CardContent className="space-y-4">
            {section.questions.map((q, qi) => {
              questionCounter += 1;
              const sourcePages = (q as { source_pages?: number[] }).source_pages ?? [];
              return (
                <div key={qi} className="rounded-md border p-3">
                  <div className="flex items-start gap-3">
                    <span className="font-medium">{questionCounter}.</span>
                    <div className="flex-1">
                      <Textarea
                        value={q.prompt}
                        onChange={(e) => {
                          const value = e.target.value;
                          setExam((prev) => {
                            const next = structuredClone(prev);
                            next.sections[si]!.questions[qi]!.prompt = value;
                            return next;
                          });
                        }}
                        className="text-sm"
                      />
                      {q.type === 'mcq' && 'options' in q && q.options ? (
                        <div className="mt-2 space-y-1">
                          {q.options.map((opt: string, oi: number) => (
                            <div key={oi} className="flex items-center gap-2 text-sm">
                              <span className="w-6 text-muted-foreground">
                                {String.fromCharCode(65 + oi)}.
                              </span>
                              <span>{opt}</span>
                            </div>
                          ))}
                        </div>
                      ) : null}
                      <div className="mt-2 text-xs text-muted-foreground">
                        Answer:{' '}
                        <span className="font-medium text-foreground">
                          {(q as { answer?: string }).answer}
                        </span>{' '}
                        · {q.marks} marks · pages {sourcePages.join(', ') || '—'}
                      </div>
                    </div>
                    <div className="flex flex-col gap-1">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => regenerate(si, qi)}
                        disabled={busy === `r-${si}-${qi}`}
                      >
                        {busy === `r-${si}-${qi}` ? '…' : 'Regenerate'}
                      </Button>
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => saveToBank(si, qi)}
                        disabled={busy === `bank-${si}-${qi}`}
                      >
                        {busy === `bank-${si}-${qi}` ? '…' : 'Save to bank'}
                      </Button>
                    </div>
                  </div>
                </div>
              );
            })}
          </CardContent>
        </Card>
      ))}

      <div className="flex justify-end">
        <Button onClick={() => savePayload(exam)} disabled={busy === 'save'} variant="outline">
          {busy === 'save' ? 'Saving…' : 'Save edits'}
        </Button>
      </div>

      <div className="space-y-3 pt-4">
        <h2 className="text-xl font-semibold">Student Submissions (auto-grading)</h2>
        <SubmissionsPanel examId={examId} />
      </div>
    </div>
  );
}
