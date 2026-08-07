'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { createTeachableSubject } from './actions';
import { createTeachableSubjectSchema, type CreateTeachableSubjectInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

const NONE = '__none__';

type Staff = { user_id: string; full_name: string };
type Subject = { id: string; code: string; name_en: string };
type ClassLevel = { id: string; code: string; name_en: string; ordinal: number };
type Stream = { id: string; code: string; name_en: string };

export function CreateTeachableSubjectForm({
  staff,
  subjects,
  classLevels,
  streams,
}: {
  staff: Staff[];
  subjects: Subject[];
  classLevels: ClassLevel[];
  streams: Stream[];
}) {
  const [pending, startTransition] = useTransition();
  const {
    control,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<CreateTeachableSubjectInput>({ resolver: zodResolver(createTeachableSubjectSchema) });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('staffId', values.staffId);
    fd.set('subjectId', values.subjectId);
    fd.set('classLevelFromId', values.classLevelFromId);
    fd.set('classLevelToId', values.classLevelToId);
    if (values.streamId) fd.set('streamId', values.streamId);

    startTransition(async () => {
      const result = await createTeachableSubject({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Approval added.');
        reset({ staffId: undefined, subjectId: undefined, classLevelFromId: undefined, classLevelToId: undefined, streamId: undefined });
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-5" data-testid="create-teachable-subject-form" noValidate>
      <div className="space-y-1">
        <Label htmlFor="grant-staff">Teacher</Label>
        <Controller
          control={control}
          name="staffId"
          render={({ field }) => (
            <Select value={field.value ?? ''} onValueChange={field.onChange}>
              <SelectTrigger data-testid="grant-staff-trigger">
                <SelectValue placeholder="Choose teacher" />
              </SelectTrigger>
              <SelectContent>
                {staff.map((s) => (
                  <SelectItem key={s.user_id} value={s.user_id}>
                    {s.full_name}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.staffId && <p className="text-xs text-destructive">{errors.staffId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="grant-subject">Subject</Label>
        <Controller
          control={control}
          name="subjectId"
          render={({ field }) => (
            <Select value={field.value ?? ''} onValueChange={field.onChange}>
              <SelectTrigger data-testid="grant-subject-trigger">
                <SelectValue placeholder="Choose subject" />
              </SelectTrigger>
              <SelectContent>
                {subjects.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name_en} ({s.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.subjectId && <p className="text-xs text-destructive">{errors.subjectId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="grant-from">From class</Label>
        <Controller
          control={control}
          name="classLevelFromId"
          render={({ field }) => (
            <Select value={field.value ?? ''} onValueChange={field.onChange}>
              <SelectTrigger data-testid="grant-from-trigger">
                <SelectValue placeholder="From" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.classLevelFromId && <p className="text-xs text-destructive">{errors.classLevelFromId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="grant-to">To class</Label>
        <Controller
          control={control}
          name="classLevelToId"
          render={({ field }) => (
            <Select value={field.value ?? ''} onValueChange={field.onChange}>
              <SelectTrigger data-testid="grant-to-trigger">
                <SelectValue placeholder="To" />
              </SelectTrigger>
              <SelectContent>
                {classLevels.map((c) => (
                  <SelectItem key={c.id} value={c.id}>
                    {c.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.classLevelToId && <p className="text-xs text-destructive">{errors.classLevelToId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="grant-stream">Stream (optional)</Label>
        <Controller
          control={control}
          name="streamId"
          render={({ field }) => (
            <Select value={field.value || NONE} onValueChange={(v) => field.onChange(v === NONE ? undefined : v)}>
              <SelectTrigger data-testid="grant-stream-trigger">
                <SelectValue placeholder="Any stream" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value={NONE}>Any stream</SelectItem>
                {streams.map((s) => (
                  <SelectItem key={s.id} value={s.id}>
                    {s.name_en}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
      </div>
      <Button type="submit" disabled={pending} data-testid="create-teachable-subject-button" className="col-span-full w-fit">
        {pending ? 'Saving…' : 'Add approval'}
      </Button>
    </form>
  );
}
