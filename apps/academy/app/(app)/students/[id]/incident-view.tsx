'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { recordIncident } from './incident-actions';
import { formatDatePk, todayPk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';

export type IncidentRow = {
  id: string;
  occurred_on: string;
  category: string;
  severity: string;
  description: string;
  action_taken: string | null;
  parent_informed: boolean;
};

const CATEGORIES = {
  behaviour: 'Behaviour',
  bullying: 'Bullying',
  attendance: 'Attendance',
  uniform: 'Uniform',
  academic_dishonesty: 'Cheating',
  property_damage: 'Property damage',
  other: 'Other',
} as const;
const SEVERITY_BADGE = { minor: 'outline', moderate: 'warning', serious: 'destructive' } as const;

const schema = z.object({
  occurredOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  category: z.enum(Object.keys(CATEGORIES) as [keyof typeof CATEGORIES, ...(keyof typeof CATEGORIES)[]]),
  severity: z.enum(['minor', 'moderate', 'serious']),
  description: z.string().trim().min(1, 'Describe what happened').max(2000),
  actionTaken: z.string().trim().max(1000).optional(),
  parentInformed: z.boolean(),
});
type Values = z.infer<typeof schema>;

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function IncidentView({ studentId, incidents }: { studentId: string; incidents: IncidentRow[] }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, reset, formState: { errors } } = useForm<Values>({
    resolver: zodResolver(schema),
    defaultValues: { occurredOn: todayPk(), category: 'behaviour', severity: 'minor', parentInformed: false },
  });

  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await recordIncident({ ...v, studentId });
      if (r.error) return void toast.error(r.error);
      toast.success('Incident recorded.');
      reset({ occurredOn: todayPk(), category: 'behaviour', severity: 'minor', parentInformed: false, description: '', actionTaken: '' });
    }),
  );

  return (
    <div className="space-y-3">
      {incidents.length === 0 ? (
        <p className="text-sm text-muted-foreground">No incidents recorded.</p>
      ) : (
        <ul className="space-y-2 text-sm" data-testid="incident-list">
          {incidents.map((i) => (
            <li key={i.id} className="rounded-md border p-3">
              <div className="flex flex-wrap items-center gap-2">
                <span className="font-medium">{formatDatePk(i.occurred_on)}</span>
                <Badge variant={SEVERITY_BADGE[i.severity as keyof typeof SEVERITY_BADGE] ?? 'outline'}>{i.severity}</Badge>
                <span>{CATEGORIES[i.category as keyof typeof CATEGORIES] ?? i.category}</span>
                {i.parent_informed && <span className="text-muted-foreground">· parent informed</span>}
              </div>
              <p className="mt-1">{i.description}</p>
              {i.action_taken && <p className="text-muted-foreground">Action: {i.action_taken}</p>}
            </li>
          ))}
        </ul>
      )}
      <details className="rounded-md border p-3">
        <summary className="cursor-pointer text-sm font-medium">Record an incident</summary>
        <form onSubmit={onSubmit} className="mt-3 grid gap-3 sm:grid-cols-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="inc-date">Date</Label>
            <Input id="inc-date" type="date" max={todayPk()} {...register('occurredOn')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="inc-category">Type</Label>
            <select id="inc-category" className={SELECT} {...register('category')}>
              {Object.entries(CATEGORIES).map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="inc-severity">Severity</Label>
            <select id="inc-severity" className={SELECT} {...register('severity')}>
              <option value="minor">Minor</option>
              <option value="moderate">Moderate</option>
              <option value="serious">Serious</option>
            </select>
          </div>
          <div className="space-y-1 sm:col-span-3">
            <Label htmlFor="inc-description">What happened</Label>
            <Textarea id="inc-description" {...register('description')} />
            {errors.description && <p className="text-sm text-destructive">{errors.description.message}</p>}
          </div>
          <div className="space-y-1 sm:col-span-2">
            <Label htmlFor="inc-action">Action taken</Label>
            <Input id="inc-action" {...register('actionTaken')} />
          </div>
          <label className="flex items-center gap-2 self-end text-sm">
            <input type="checkbox" {...register('parentInformed')} /> Parent informed
          </label>
          <Button type="submit" disabled={pending} className="sm:col-span-3 sm:w-fit">
            Save incident
          </Button>
        </form>
      </details>
    </div>
  );
}
