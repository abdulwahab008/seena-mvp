'use client';

import { useMemo, useState, useTransition } from 'react';
import { useForm, useWatch, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createHomework } from './actions';
import { createHomeworkSchema, type CreateHomeworkInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { DatePicker } from '@/components/ui/date-picker';

type Assignment = { sectionId: string; sectionLabel: string; subjectId: string; subjectLabel: string };

const todayIso = () => new Date().toISOString().slice(0, 10);

export function CreateHomeworkForm({ assignments }: { assignments: Assignment[] }) {
  const [pending, startTransition] = useTransition();
  const [publishNow, setPublishNow] = useState(false);
  const key = (a: Assignment) => `${a.sectionId}::${a.subjectId}`;

  const {
    register,
    handleSubmit,
    control,
    setValue,
    reset,
    formState: { errors },
  } = useForm<CreateHomeworkInput>({
    resolver: zodResolver(createHomeworkSchema),
    defaultValues: {
      sectionId: assignments[0]?.sectionId,
      subjectId: assignments[0]?.subjectId,
      assignedDate: todayIso(),
      // '' not undefined: the DatePicker is only controlled while its value is a string, so an
      // undefined (reset) value would leave the previous date on screen while the form is empty.
      dueDate: '',
    },
  });

  const options = useMemo(() => assignments, [assignments]);
  const sectionId = useWatch({ control, name: 'sectionId' });
  const subjectId = useWatch({ control, name: 'subjectId' });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('sectionId', values.sectionId);
    fd.set('subjectId', values.subjectId);
    fd.set('title', values.title);
    if (values.description) fd.set('description', values.description);
    fd.set('assignedDate', values.assignedDate);
    fd.set('dueDate', values.dueDate);
    if (values.estimatedMinutes) fd.set('estimatedMinutes', String(values.estimatedMinutes));
    if (publishNow) fd.set('publishNow', 'on');

    startTransition(async () => {
      const result = await createHomework({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(publishNow ? 'Homework published.' : 'Homework saved as draft.');
        // publishNow lives outside react-hook-form's own state, so reset()
        // alone won't touch it — left checked, the next assignment would
        // silently publish too instead of defaulting back to draft.
        setPublishNow(false);
        reset({ sectionId: values.sectionId, subjectId: values.subjectId, assignedDate: todayIso(), dueDate: '' });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
      <div className="col-span-2 space-y-1 md:col-span-2">
        <Label htmlFor="assignment">Section · Subject</Label>
        <Select
          value={key({ sectionId, subjectId } as Assignment)}
          onValueChange={(v) => {
            const match = options.find((a) => key(a) === v);
            if (!match) return;
            setValue('sectionId', match.sectionId);
            setValue('subjectId', match.subjectId);
          }}
        >
          <SelectTrigger data-testid="homework-assignment-trigger">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {options.map((a) => (
              <SelectItem key={key(a)} value={key(a)}>
                {a.sectionLabel} · {a.subjectLabel}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>
      <div className="col-span-2 space-y-1 md:col-span-2">
        <Label htmlFor="title">Title</Label>
        <Input id="title" placeholder="Chapter 3 exercises" {...register('title')} />
        {errors.title && <p className="text-xs text-destructive">{errors.title.message}</p>}
      </div>
      <div className="col-span-2 space-y-1 md:col-span-4">
        <Label htmlFor="description">Description (optional, Urdu supported)</Label>
        <textarea
          id="description"
          rows={3}
          className="w-full rounded-md border px-3 py-2 text-sm"
          {...register('description')}
        />
        {errors.description && <p className="text-xs text-destructive">{errors.description.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="assignedDate">Assigned date</Label>
        <Controller
          control={control}
          name="assignedDate"
          render={({ field }) => (
            <DatePicker
              id="assignedDate"
              name="assignedDate"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="Assigned date"
              data-testid="assigned-date-picker"
            />
          )}
        />
      </div>
      <div className="space-y-1">
        <Label htmlFor="dueDate">Due date</Label>
        <Controller
          control={control}
          name="dueDate"
          render={({ field }) => (
            <DatePicker
              id="dueDate"
              name="dueDate"
              value={field.value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              placeholder="Due date"
              data-testid="due-date-picker"
            />
          )}
        />
        {errors.dueDate && <p className="text-xs text-destructive">{errors.dueDate.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="estimatedMinutes">Est. minutes (optional)</Label>
        <Input id="estimatedMinutes" type="number" min={1} {...register('estimatedMinutes')} />
      </div>
      <label className="flex items-center gap-2 self-end pb-2 text-sm">
        <input type="checkbox" checked={publishNow} onChange={(e) => setPublishNow(e.target.checked)} />
        Publish now
      </label>
      <Button type="submit" disabled={pending} className="col-span-full w-fit">
        {pending ? 'Saving…' : publishNow ? 'Publish homework' : 'Save as draft'}
      </Button>
    </form>
  );
}
