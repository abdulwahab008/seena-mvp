'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { setElectiveChoice } from '../actions';
import { setStudentElectiveChoiceSchema, type SetStudentElectiveChoiceInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type ElectiveOption = { subjectId: string; code: string; nameEn: string };
export type ElectiveBucket = { bucket: number; options: ElectiveOption[]; chosenSubjectId: string | null };

function BucketRow({
  studentId,
  sessionId,
  classLevelId,
  bucket,
}: {
  studentId: string;
  sessionId: string;
  classLevelId: string;
  bucket: ElectiveBucket;
}) {
  const [pending, startTransition] = useTransition();
  const {
    control,
    handleSubmit,
    formState: { errors },
  } = useForm<SetStudentElectiveChoiceInput>({
    resolver: zodResolver(setStudentElectiveChoiceSchema),
    defaultValues: { sessionId, classLevelId, electiveBucket: bucket.bucket, subjectId: bucket.chosenSubjectId ?? '' },
  });

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('sessionId', values.sessionId);
    fd.set('classLevelId', values.classLevelId);
    fd.set('electiveBucket', String(values.electiveBucket));
    fd.set('subjectId', values.subjectId);

    startTransition(async () => {
      const result = await setElectiveChoice(studentId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else toast.success('Elective choice saved.');
    });
  });

  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2 rounded-lg border p-3" data-testid={`elective-bucket-${bucket.bucket}`}>
      <div className="space-y-1">
        <p className="text-sm font-medium">Bucket {bucket.bucket}</p>
        <Controller
          control={control}
          name="subjectId"
          render={({ field }) => (
            <Select value={field.value} onValueChange={field.onChange}>
              <SelectTrigger data-testid={`elective-bucket-${bucket.bucket}-trigger`} className="w-56">
                <SelectValue placeholder="Choose subject" />
              </SelectTrigger>
              <SelectContent>
                {bucket.options.map((o) => (
                  <SelectItem key={o.subjectId} value={o.subjectId}>
                    {o.nameEn} ({o.code})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          )}
        />
        {errors.subjectId && <p className="text-xs text-destructive">{errors.subjectId.message}</p>}
      </div>
      <Button type="submit" size="sm" disabled={pending}>
        {pending ? 'Saving…' : 'Save'}
      </Button>
    </form>
  );
}

export function ElectiveChoiceView({
  studentId,
  sessionId,
  classLevelId,
  buckets,
}: {
  studentId: string;
  sessionId: string;
  classLevelId: string;
  buckets: ElectiveBucket[];
}) {
  if (buckets.length === 0) {
    return <p className="text-sm text-muted-foreground">No elective buckets are configured for this class level.</p>;
  }
  return (
    <div className="space-y-2">
      {buckets.map((b) => (
        <BucketRow key={b.bucket} studentId={studentId} sessionId={sessionId} classLevelId={classLevelId} bucket={b} />
      ))}
    </div>
  );
}
