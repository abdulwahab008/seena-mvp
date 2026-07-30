'use client';

import { useMemo, useState, useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { toast } from 'sonner';
import { upsertClassSubject, copyClassSubjectMap } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

const WEEKLY_SLOT_LIMIT = 40; // campus bell template stand-in — see migration header

type ClassLevel = { id: string; code: string; name_en: string; ordinal: number };
type Subject = { id: string; code: string; name_en: string };
type Mapping = {
  id: string;
  class_level_id: string;
  subject_id: string;
  weekly_periods: number;
  is_compulsory: boolean;
  elective_bucket: number | null;
};
type WeeklyLoad = { class_level_id: string | null; total_weekly_periods: number | null };

type FormValues = {
  subjectId: string;
  weeklyPeriods: string;
  isCompulsory: boolean;
  electiveBucket: string;
  chooseN: string;
};

export function CurriculumMapper({
  campusId,
  sessionId,
  classLevels,
  subjects,
  mappings,
  weeklyLoad,
}: {
  campusId: string;
  sessionId: string;
  classLevels: ClassLevel[];
  subjects: Subject[];
  mappings: Mapping[];
  weeklyLoad: WeeklyLoad[];
}) {
  const [pending, startTransition] = useTransition();
  const [classLevelId, setClassLevelId] = useState(classLevels[0]?.id ?? '');
  const { register, handleSubmit, control, reset, watch } = useForm<FormValues>({
    defaultValues: { isCompulsory: true, electiveBucket: '', chooseN: '' },
  });
  const isCompulsory = watch('isCompulsory');

  const rows = useMemo(() => mappings.filter((m) => m.class_level_id === classLevelId), [mappings, classLevelId]);
  const total = weeklyLoad.find((w) => w.class_level_id === classLevelId)?.total_weekly_periods ?? 0;
  const subjectName = (id: string) => subjects.find((s) => s.id === id)?.name_en ?? id;

  const nextClassLevel = useMemo(() => {
    const current = classLevels.find((c) => c.id === classLevelId);
    if (!current) return null;
    return classLevels.filter((c) => c.ordinal > current.ordinal).sort((a, b) => a.ordinal - b.ordinal)[0] ?? null;
  }, [classLevels, classLevelId]);

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('campusId', campusId);
    fd.set('sessionId', sessionId);
    fd.set('classLevelId', classLevelId);
    fd.set('subjectId', values.subjectId);
    fd.set('weeklyPeriods', values.weeklyPeriods);
    if (values.isCompulsory) fd.set('isCompulsory', 'on');
    if (values.electiveBucket) fd.set('electiveBucket', values.electiveBucket);
    if (values.chooseN) fd.set('chooseN', values.chooseN);

    startTransition(async () => {
      const result = await upsertClassSubject({ error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success(`${subjectName(values.subjectId)} mapped.`);
        reset({ isCompulsory: true, electiveBucket: '', chooseN: '' });
      }
    });
  });

  const onCopyToNext = () => {
    if (!nextClassLevel) return;
    startTransition(async () => {
      const result = await copyClassSubjectMap(classLevelId, nextClassLevel.id, sessionId, campusId);
      if (result.error || !result.result) toast.error(result.error ?? 'Could not copy.');
      else toast.success(`Copied to ${nextClassLevel.name_en}: ${result.result.created} created, ${result.result.skipped} skipped.`);
    });
  };

  return (
    <div className="space-y-4">
      <div className="max-w-xs space-y-1">
        <Label>Class</Label>
        <Select value={classLevelId} onValueChange={setClassLevelId}>
          <SelectTrigger data-testid="curriculum-class-trigger">
            <SelectValue placeholder="Select a class" />
          </SelectTrigger>
          <SelectContent>
            {classLevels.map((c) => (
              <SelectItem key={c.id} value={c.id}>
                {c.name_en}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="rounded-lg border">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-muted-foreground">
              <th className="p-2">Subject</th>
              <th className="p-2">Weekly periods</th>
              <th className="p-2">Type</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id} data-testid={`curriculum-row-${subjectName(r.subject_id)}`} className="border-b last:border-0">
                <td className="p-2">{subjectName(r.subject_id)}</td>
                <td className="p-2">{r.weekly_periods}</td>
                <td className="p-2 text-muted-foreground">
                  {r.is_compulsory ? 'Compulsory' : `Elective (bucket ${r.elective_bucket})`}
                </td>
              </tr>
            ))}
            {rows.length === 0 && (
              <tr>
                <td className="p-2 text-muted-foreground" colSpan={3}>
                  No subjects mapped yet.
                </td>
              </tr>
            )}
          </tbody>
        </table>
        <div
          data-testid="curriculum-total"
          className={`border-t p-2 text-sm font-medium ${total > WEEKLY_SLOT_LIMIT ? 'text-destructive' : ''}`}
        >
          Total weekly periods: {total} / {WEEKLY_SLOT_LIMIT}
        </div>
      </div>

      {nextClassLevel && (
        <Button type="button" variant="outline" size="sm" disabled={pending} onClick={onCopyToNext}>
          Copy this map to {nextClassLevel.name_en}
        </Button>
      )}

      <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 rounded-lg border p-4 md:grid-cols-4" noValidate>
        <div className="space-y-1">
          <Label htmlFor="subjectId">Subject</Label>
          <Controller
            control={control}
            name="subjectId"
            rules={{ required: true }}
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="curriculum-subject-trigger">
                  <SelectValue placeholder="Select a subject" />
                </SelectTrigger>
                <SelectContent>
                  {subjects.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name_en}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
        </div>
        <div className="space-y-1">
          <Label htmlFor="weeklyPeriods">Weekly periods</Label>
          <Input id="weeklyPeriods" type="number" min={1} max={12} {...register('weeklyPeriods', { required: true })} />
        </div>
        <label className="flex items-center gap-2 self-end pb-2 text-sm">
          <input type="checkbox" {...register('isCompulsory')} />
          Compulsory
        </label>
        {!isCompulsory && (
          <>
            <div className="space-y-1">
              <Label htmlFor="electiveBucket">Elective bucket</Label>
              <Input id="electiveBucket" type="number" min={1} {...register('electiveBucket')} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="chooseN">Choose N</Label>
              <Input id="chooseN" type="number" min={1} {...register('chooseN')} />
            </div>
          </>
        )}
        <Button type="submit" disabled={pending} className="col-span-full w-fit">
          {pending ? 'Saving…' : 'Map subject'}
        </Button>
      </form>
    </div>
  );
}
