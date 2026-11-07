'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { addQuestion, createQuiz, publishQuiz } from './actions';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const localInput = (d: Date) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);

const quizSchema = z.object({
  sectionId: z.string().min(1, 'Choose a section'),
  title: z.string().trim().min(1, 'Enter a title').max(200),
  opensAt: z.string().min(1, 'Choose when it opens'),
  closesAt: z.string().min(1, 'Choose when it closes'),
  durationMin: z.string().regex(/^\d+$/, 'Enter minutes'),
});

export function NewQuizForm({ sections }: { sections: { id: string; label: string }[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const now = new Date();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof quizSchema>>({
    resolver: zodResolver(quizSchema),
    defaultValues: { sectionId: '', title: '', opensAt: localInput(now), closesAt: localInput(new Date(now.getTime() + 7 * 86_400_000)), durationMin: '20' },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await createQuiz({ ...v, opensAt: new Date(v.opensAt).toISOString(), closesAt: new Date(v.closesAt).toISOString() });
      if (r.error) return void toast.error(r.error);
      router.push(`/quizzes/${r.id}`);
    }),
  );
  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle className="text-base">New quiz</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="quiz-section">Class and section</Label>
            <select id="quiz-section" className={SELECT} {...register('sectionId')}>
              <option value="">Choose a section</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            {errors.sectionId && <p className="text-sm text-destructive">{errors.sectionId.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="quiz-title">Title</Label>
            <Input id="quiz-title" {...register('title')} />
            {errors.title && <p className="text-sm text-destructive">{errors.title.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="quiz-opens">Opens</Label>
            <Input id="quiz-opens" type="datetime-local" {...register('opensAt')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="quiz-closes">Closes</Label>
            <Input id="quiz-closes" type="datetime-local" {...register('closesAt')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="quiz-duration">Time limit (minutes)</Label>
            <Input id="quiz-duration" type="number" min={1} max={300} {...register('durationMin')} />
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            Create and add questions
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

const questionSchema = z.object({
  prompt: z.string().trim().min(1, 'Enter the question').max(2000),
  options: z.string().min(1, 'Enter the options'),
  correct: z.string().regex(/^\d$/, 'Enter the number of the right option'),
  marks: z.string().regex(/^\d+$/, 'Enter marks'),
});

export function QuestionForm({ quizId }: { quizId: string }) {
  const [pending, startTransition] = useTransition();
  const blank = { prompt: '', options: '', correct: '1', marks: '1' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof questionSchema>>({ resolver: zodResolver(questionSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const options = v.options.split('\n').map((o) => o.trim()).filter(Boolean);
      const r = await addQuestion({ quizId, prompt: v.prompt, options, correct: v.correct, marks: v.marks });
      if (r.error) return void toast.error(r.error);
      toast.success('Question added.');
      reset(blank);
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Add a question</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2" noValidate>
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="q-prompt">Question</Label>
            <Textarea id="q-prompt" {...register('prompt')} />
            {errors.prompt && <p className="text-sm text-destructive">{errors.prompt.message}</p>}
          </div>
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="q-options">Options, one per line (2 to 6)</Label>
            <Textarea id="q-options" rows={4} {...register('options')} />
            {errors.options && <p className="text-sm text-destructive">{errors.options.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="q-correct">Right option number</Label>
            <Input id="q-correct" type="number" min={1} max={6} {...register('correct')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="q-marks">Marks</Label>
            <Input id="q-marks" type="number" min={1} max={100} {...register('marks')} />
          </div>
          <Button type="submit" disabled={pending} className="sm:w-fit">
            Add question
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export function PublishButton({ quizId }: { quizId: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await publishQuiz(quizId);
          if (r.error) toast.error(r.error);
          else toast.success('Published. Students can take it when it opens.');
        })
      }
    >
      Publish quiz
    </Button>
  );
}
