'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { handleGrievance, raiseGrievance } from './actions';
import { formatDatePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';

const CATEGORY: Record<string, string> = { pay: 'Pay', workload: 'Workload', conduct: 'Conduct', harassment: 'Harassment', facilities: 'Facilities', policy: 'Policy', other: 'Other' };
const STATUS: Record<string, { label: string; variant: 'warning' | 'primary' | 'success' | 'outline' }> = {
  open: { label: 'Open', variant: 'warning' },
  in_review: { label: 'In review', variant: 'primary' },
  resolved: { label: 'Resolved', variant: 'success' },
  dismissed: { label: 'Dismissed', variant: 'outline' },
};
const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

const raiseSchema = z.object({
  category: z.string().min(1),
  subject: z.string().trim().min(1, 'Enter a subject').max(200),
  description: z.string().trim().min(1, 'Describe the problem').max(4000),
});

export function RaiseForm() {
  const [pending, startTransition] = useTransition();
  const blank = { category: 'workload', subject: '', description: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof raiseSchema>>({ resolver: zodResolver(raiseSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await raiseGrievance(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Sent to HR.');
      reset(blank);
    }),
  );
  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle className="text-base">Raise a grievance</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="gr-category">About</Label>
            <select id="gr-category" className={SELECT} {...register('category')}>
              {Object.entries(CATEGORY).map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </select>
          </div>
          <div className="space-y-1">
            <Label htmlFor="gr-subject">Subject</Label>
            <Input id="gr-subject" {...register('subject')} />
            {errors.subject && <p className="text-sm text-destructive">{errors.subject.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="gr-description">What is the problem?</Label>
            <Textarea id="gr-description" rows={5} {...register('description')} />
            {errors.description && <p className="text-sm text-destructive">{errors.description.message}</p>}
          </div>
          <Button type="submit" disabled={pending} className="w-full">
            Send to HR
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

type Grievance = { id: string; category: string; subject: string; description: string; status: string; resolution: string | null; created_at: string };
const handleSchema = z.object({ resolution: z.string().max(2000) });

function HandleModal({ grievance, status, onClose }: { grievance: Grievance; status: 'in_review' | 'resolved' | 'dismissed'; onClose: () => void }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<z.infer<typeof handleSchema>>({ resolver: zodResolver(handleSchema), defaultValues: { resolution: '' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await handleGrievance({ id: grievance.id, status, resolution: v.resolution || undefined });
      if (r.error) return void toast.error(r.error);
      toast.success('Updated.');
      onClose();
    }),
  );
  return (
    <Modal
      open
      onClose={onClose}
      title={`${STATUS[status]?.label}: ${grievance.subject}`}
      size="sm"
      footer={
        <>
          <Button variant="outline" onClick={onClose} disabled={pending}>Cancel</Button>
          <Button type="submit" form="handle-form" disabled={pending}>Save</Button>
        </>
      }
    >
      <form id="handle-form" onSubmit={onSubmit} className="space-y-1" noValidate>
        <Label htmlFor="handle-resolution">{status === 'in_review' ? 'Note (optional)' : 'Outcome (the person who raised it will see this)'}</Label>
        <Textarea id="handle-resolution" {...register('resolution')} />
      </form>
    </Modal>
  );
}

export function GrievanceList({ title, grievances, canHandle }: { title: string; grievances: Grievance[]; canHandle: boolean }) {
  const [handling, setHandling] = useState<{ grievance: Grievance; status: 'in_review' | 'resolved' | 'dismissed' } | null>(null);
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">
          {title} ({grievances.length})
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-2 text-sm">
        {grievances.length === 0 && <p className="text-muted-foreground">None.</p>}
        {grievances.map((g) => (
          <div key={g.id} className="space-y-1 rounded-md border p-3" data-testid="grievance-row">
            <div className="flex flex-wrap items-center gap-2">
              <span className="font-medium">{g.subject}</span>
              <Badge variant={STATUS[g.status]?.variant ?? 'outline'} data-testid="grievance-status">{STATUS[g.status]?.label ?? g.status}</Badge>
              <span className="text-muted-foreground">
                {CATEGORY[g.category]} · {formatDatePk(g.created_at)}
              </span>
            </div>
            <p className="whitespace-pre-wrap">{g.description}</p>
            {g.resolution && <p className="text-muted-foreground">Outcome: {g.resolution}</p>}
            {canHandle && ['open', 'in_review'].includes(g.status) && (
              <div className="flex gap-1 pt-1">
                {g.status === 'open' && (
                  <Button size="sm" variant="outline" onClick={() => setHandling({ grievance: g, status: 'in_review' })}>
                    Start review
                  </Button>
                )}
                <Button size="sm" variant="outline" onClick={() => setHandling({ grievance: g, status: 'resolved' })}>
                  Resolve
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setHandling({ grievance: g, status: 'dismissed' })}>
                  Dismiss
                </Button>
              </div>
            )}
          </div>
        ))}
      </CardContent>
      {handling && <HandleModal grievance={handling.grievance} status={handling.status} onClose={() => setHandling(null)} />}
    </Card>
  );
}
