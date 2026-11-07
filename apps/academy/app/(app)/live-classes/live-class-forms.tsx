'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { cancelLiveClass, scheduleLiveClass } from './actions';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const localInput = (d: Date) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
type Option = { id: string; label: string };

const schema = z.object({
  sectionId: z.string().min(1, 'Choose a section'),
  subjectId: z.string(),
  title: z.string().trim().min(1, 'Enter a title').max(150),
  startsAt: z.string().min(1, 'Choose when it starts'),
  durationMin: z.string().regex(/^\d+$/, 'Enter minutes'),
  meetingUrl: z.string().trim().startsWith('https://', 'Paste the https:// meeting link'),
});

export function LiveClassForm({ sections, subjects }: { sections: Option[]; subjects: Option[] }) {
  const [pending, startTransition] = useTransition();
  const blank = { sectionId: '', subjectId: '', title: '', startsAt: localInput(new Date(Date.now() + 3600_000)), durationMin: '40', meetingUrl: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await scheduleLiveClass({ ...v, startsAt: new Date(v.startsAt).toISOString() });
      if (r.error) return void toast.error(r.error);
      toast.success('Live class scheduled.');
      reset(blank);
    }),
  );
  const field = (id: keyof z.infer<typeof schema>, label: string, input: React.ReactNode) => (
    <div className="space-y-1">
      <Label htmlFor={`lc-${id}`}>{label}</Label>
      {input}
      {errors[id] && <p className="text-sm text-destructive">{errors[id]?.message}</p>}
    </div>
  );
  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle className="text-base">Schedule a class</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          {field(
            'sectionId',
            'Section',
            <select id="lc-sectionId" className={SELECT} {...register('sectionId')}>
              <option value="">Choose…</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>,
          )}
          {field(
            'subjectId',
            'Subject (optional)',
            <select id="lc-subjectId" className={SELECT} {...register('subjectId')}>
              <option value="">None</option>
              {subjects.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>,
          )}
          {field('title', 'Title', <Input id="lc-title" {...register('title')} />)}
          {field('startsAt', 'Starts at', <Input id="lc-startsAt" type="datetime-local" {...register('startsAt')} />)}
          {field('durationMin', 'Minutes', <Input id="lc-durationMin" inputMode="numeric" {...register('durationMin')} />)}
          {field('meetingUrl', 'Meeting link', <Input id="lc-meetingUrl" placeholder="https://meet.google.com/…" {...register('meetingUrl')} />)}
          <Button type="submit" disabled={pending} className="w-full">
            Schedule
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

export function CancelLiveClass({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await cancelLiveClass(id);
          if (r.error) return void toast.error(r.error);
          toast.success('Class cancelled.');
        })
      }
    >
      Cancel
    </Button>
  );
}
