'use client';

import { useEffect, useState, useTransition } from 'react';
import Link from 'next/link';
import { useForm } from 'react-hook-form';
import { startQuiz, submitQuiz, type StartedQuiz } from '../actions';
import { Button } from '@/components/ui/button';

export function TakeQuiz({ quizId }: { quizId: string }) {
  const [quiz, setQuiz] = useState<StartedQuiz | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<{ score: number; maxScore: number } | null>(null);
  const [left, setLeft] = useState<number | null>(null);
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<Record<string, string>>();

  useEffect(() => {
    startQuiz(quizId).then((r) => (r.error ? setError(r.error) : setQuiz(r.quiz!)));
  }, [quizId]);

  useEffect(() => {
    if (!quiz) return;
    const tick = () => setLeft(Math.max(0, Math.round((Date.parse(quiz.ends_at) - Date.now()) / 1000)));
    tick();
    const t = setInterval(tick, 1000);
    return () => clearInterval(t);
  }, [quiz]);

  const onSubmit = handleSubmit((values) =>
    startTransition(async () => {
      if (!quiz) return;
      const answers = quiz.questions.map((q) => (values[q.id] === undefined || values[q.id] === null ? -1 : Number(values[q.id])));
      const r = await submitQuiz(quizId, answers);
      if (r.error) setError(r.error);
      else setResult({ score: r.score!, maxScore: r.maxScore! });
    }),
  );

  if (result) {
    return (
      <div className="space-y-3">
        <h1 className="text-2xl font-semibold">Submitted</h1>
        <p className="text-lg" data-testid="quiz-score">
          You scored {result.score} out of {result.maxScore}.
        </p>
        <Link href="/student/quizzes" className="text-primary underline">
          Back to quizzes
        </Link>
      </div>
    );
  }
  if (error) {
    return (
      <div className="space-y-3">
        <p role="alert" className="text-destructive">
          {error}
        </p>
        <Link href="/student/quizzes" className="text-primary underline">
          Back to quizzes
        </Link>
      </div>
    );
  }
  if (!quiz) return <p className="text-sm text-muted-foreground">Loading the quiz…</p>;

  return (
    <form onSubmit={onSubmit} className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-2xl font-semibold">{quiz.title}</h1>
        {left !== null && (
          <span className={left < 60 ? 'font-medium text-destructive' : 'text-muted-foreground'} aria-live="polite">
            {Math.floor(left / 60)}:{String(left % 60).padStart(2, '0')} left
          </span>
        )}
      </div>
      {quiz.questions.map((q, i) => (
        <fieldset key={q.id} className="space-y-2 rounded-md border p-3">
          <legend className="px-1 font-medium">
            {i + 1}. {q.prompt} <span className="text-xs text-muted-foreground">({q.marks} marks)</span>
          </legend>
          {q.options.map((o, oi) => (
            <label key={oi} className="flex items-center gap-2 text-sm">
              <input type="radio" value={oi} {...register(q.id)} /> {o}
            </label>
          ))}
        </fieldset>
      ))}
      <Button type="submit" disabled={pending || left === 0}>
        Submit answers
      </Button>
    </form>
  );
}
