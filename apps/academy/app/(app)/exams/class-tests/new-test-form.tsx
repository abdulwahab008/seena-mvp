'use client';

import { useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { createClassTest } from './actions';
import { classTestSchema } from './schemas';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function NewTestForm({ sections, subjects, today }: { sections: { id: string; label: string }[]; subjects: { id: string; name_en: string }[]; today: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.input<typeof classTestSchema>>({
    resolver: zodResolver(classTestSchema),
    defaultValues: { sectionId: '', subjectId: '', title: '', testDate: today, totalMarks: 25 },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const res = await createClassTest(v);
      if (res.error) return void toast.error(res.error);
      toast.success('Test created. Enter the marks.');
      router.push(`/exams/class-tests/${res.id}`);
    }),
  );

  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5" noValidate>
      <div className="space-y-1">
        <Label htmlFor="ct-section">Class and section</Label>
        <select id="ct-section" className={SELECT} {...register('sectionId')}>
          <option value="">Choose…</option>
          {sections.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
        {errors.sectionId && <p className="text-xs text-destructive">{errors.sectionId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-subject">Subject</Label>
        <select id="ct-subject" className={SELECT} {...register('subjectId')}>
          <option value="">No subject</option>
          {subjects.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name_en}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-title">Test name</Label>
        <Input id="ct-title" placeholder="Weekly test 1" {...register('title')} />
        {errors.title && <p className="text-xs text-destructive">{errors.title.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-date">Date</Label>
        <Input id="ct-date" type="date" {...register('testDate')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor="ct-total">Total marks</Label>
        <Input id="ct-total" type="number" min={1} max={1000} {...register('totalMarks')} />
        {errors.totalMarks && <p className="text-xs text-destructive">{errors.totalMarks.message}</p>}
      </div>
      <div className="sm:col-span-2 lg:col-span-5">
        <Button type="submit" disabled={pending}>
          {pending ? 'Creating…' : 'Create test'}
        </Button>
      </div>
    </form>
  );
}
