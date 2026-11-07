'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { saveVaccination } from './actions';
import { vaccinationSchema, type VaccinationInput } from './schema';

export function VaccinationForm() {
  const [pending, startTransition] = useTransition();
  const blank: VaccinationInput = { grNumber: '', vaccine: '', doseNo: '1', dueOn: '', givenOn: '', notes: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<VaccinationInput>({ resolver: zodResolver(vaccinationSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveVaccination(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Vaccination saved.');
      reset(blank);
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Record a dose</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="vx-gr">GR number</Label>
            <Input id="vx-gr" {...register('grNumber')} />
            {errors.grNumber && <p className="text-sm text-destructive">{errors.grNumber.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="vx-vaccine">Vaccine</Label>
            <Input id="vx-vaccine" placeholder="Typhoid, Measles, Hepatitis B…" {...register('vaccine')} />
            {errors.vaccine && <p className="text-sm text-destructive">{errors.vaccine.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="vx-dose">Dose number</Label>
            <Input id="vx-dose" inputMode="numeric" {...register('doseNo')} />
            {errors.doseNo && <p className="text-sm text-destructive">{errors.doseNo.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="vx-due">Due on</Label>
            <Input id="vx-due" type="date" {...register('dueOn')} />
            {errors.dueOn && <p className="text-sm text-destructive">{errors.dueOn.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="vx-given">Given on</Label>
            <Input id="vx-given" type="date" max={todayPk()} {...register('givenOn')} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="vx-notes">Notes</Label>
            <Input id="vx-notes" {...register('notes')} />
          </div>
          <div>
            <Button type="submit" disabled={pending}>
              Save
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}
