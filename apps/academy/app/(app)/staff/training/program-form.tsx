'use client';

import { useTransition } from 'react';
import { Controller, useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { saveProgram } from './actions';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Checkbox } from '@/components/ui/checkbox';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const schema = z.object({
  title: z.string().trim().min(1, 'Enter a title').max(200),
  provider: z.string().max(200),
  heldOn: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Choose a date'),
  hours: z.string().regex(/^\d+(\.\d)?$/, 'Enter the hours'),
  isMandatory: z.boolean(),
  staffIds: z.array(z.string()),
});
type Values = z.infer<typeof schema>;

export function ProgramForm({ campusId, staff }: { campusId: string; staff: { id: string; name: string }[] }) {
  const [pending, startTransition] = useTransition();
  const blank: Values = { title: '', provider: '', heldOn: todayPk(), hours: '', isMandatory: false, staffIds: [] };
  const { register, control, handleSubmit, reset, formState: { errors } } = useForm<Values>({ resolver: zodResolver(schema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveProgram({ ...v, campusId });
      if (r.error) return void toast.error(r.error);
      toast.success('Training recorded.');
      reset(blank);
    }),
  );
  return (
    <Card className="h-fit">
      <CardHeader>
        <CardTitle className="text-base">Record training</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="tp-title">Program</Label>
            <Input id="tp-title" {...register('title')} />
            {errors.title && <p className="text-sm text-destructive">{errors.title.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="tp-provider">Provider</Label>
            <Input id="tp-provider" {...register('provider')} />
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div className="space-y-1">
              <Label htmlFor="tp-date">Date</Label>
              <Input id="tp-date" type="date" {...register('heldOn')} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="tp-hours">Hours</Label>
              <Input id="tp-hours" inputMode="decimal" {...register('hours')} />
              {errors.hours && <p className="text-sm text-destructive">{errors.hours.message}</p>}
            </div>
          </div>
          <label className="flex items-center gap-2 text-sm">
            <input type="checkbox" {...register('isMandatory')} /> Mandatory for all staff
          </label>
          <fieldset className="space-y-1">
            <legend className="text-sm font-medium">Attended</legend>
            <Controller
              control={control}
              name="staffIds"
              render={({ field }) => (
                <div className="max-h-56 space-y-1 overflow-y-auto rounded-md border p-2">
                  {staff.map((s) => (
                    <span key={s.id} className="flex items-center gap-2 text-sm">
                      <Checkbox
                        id={`tp-staff-${s.id}`}
                        checked={field.value.includes(s.id)}
                        onCheckedChange={(on) => field.onChange(on ? [...field.value, s.id] : field.value.filter((x) => x !== s.id))}
                      />
                      <label htmlFor={`tp-staff-${s.id}`}>{s.name}</label>
                    </span>
                  ))}
                  {staff.length === 0 && <p className="text-sm text-muted-foreground">No staff on this campus.</p>}
                </div>
              )}
            />
          </fieldset>
          <Button type="submit" disabled={pending} className="w-full">
            Save
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}
