'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { lessonPlanSchema, type LessonPlanInput } from '@/lib/validation';
import { createPlan, setPlanStatus } from './actions';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';

export type TopicGroup = { unitId: string; unitTitle: string; topics: { id: string; title: string }[] };

export function PlanForm({ sectionId, subjectId, weekStart, groups }: { sectionId: string; subjectId: string; weekStart: string; groups: TopicGroup[] }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const form = useForm<LessonPlanInput>({ resolver: zodResolver(lessonPlanSchema), defaultValues: { sectionId, subjectId, weekStart, objectives: '', resources: '', topicIds: [] } });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await createPlan(v);
      setError(r.error);
      if (!r.error) {
        toast.success('Lesson plan saved.');
        router.refresh();
      }
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-1">
        <Label htmlFor="objectives">Learning objectives (up to 1000 characters)</Label>
        <textarea id="objectives" rows={3} className="w-full rounded-md border bg-background px-3 py-2 text-sm" {...form.register('objectives')} />
        {form.formState.errors.objectives && <p className="text-xs text-destructive">{form.formState.errors.objectives.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="resources">Resources (optional)</Label>
        <textarea id="resources" rows={2} className="w-full rounded-md border bg-background px-3 py-2 text-sm" {...form.register('resources')} />
      </div>
      <fieldset className="space-y-2" data-testid="topic-picker">
        <legend className="text-sm font-medium">Topics to cover this week</legend>
        {groups.length === 0 && <p className="text-sm text-muted-foreground">No syllabus has been defined for this class and subject yet.</p>}
        {groups.map((g) => (
          <div key={g.unitId} className="space-y-1">
            <p className="text-sm text-muted-foreground">{g.unitTitle}</p>
            {g.topics.map((t) => (
              <label key={t.id} className="flex items-center gap-2 pl-3 text-sm">
                <input type="checkbox" value={t.id} {...form.register('topicIds')} />
                {t.title}
              </label>
            ))}
          </div>
        ))}
      </fieldset>
      {error && <p role="alert" className="text-sm text-destructive" data-testid="plan-error">{error}</p>}
      <Button type="submit" disabled={pending} data-testid="save-plan">
        Save plan
      </Button>
    </form>
  );
}

export function StatusButtons({ planId, status }: { planId: string; status: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const [error, setError] = useState<string | null>(null);
  const set = (next: 'planned' | 'in_progress' | 'completed') =>
    startTransition(async () => {
      const r = await setPlanStatus(planId, next);
      setError(r.error);
      if (!r.error) router.refresh();
    });
  return (
    <span className="flex items-center gap-1">
      {status !== 'in_progress' && status !== 'completed' && (
        <Button size="sm" variant="outline" disabled={pending} onClick={() => set('in_progress')}>
          Start
        </Button>
      )}
      {status !== 'completed' ? (
        <Button size="sm" disabled={pending} onClick={() => set('completed')} data-testid="complete-plan">
          Mark complete
        </Button>
      ) : (
        <Button size="sm" variant="ghost" disabled={pending} onClick={() => set('planned')}>
          Reopen
        </Button>
      )}
      {error && <span role="alert" className="text-xs text-destructive">{error}</span>}
    </span>
  );
}
