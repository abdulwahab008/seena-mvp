'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Label } from '@/components/ui/label';
import { setManager } from './actions';
import { managerSchema, type ManagerInput } from './schema';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';

export function ManagerForm({ staff }: { staff: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const blank: ManagerInput = { staffId: '', managerId: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<ManagerInput>({ resolver: zodResolver(managerSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await setManager(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Org chart updated.');
      reset(blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-2 sm:grid-cols-[1fr_1fr_auto] sm:items-end" noValidate>
      <div className="space-y-1">
        <Label htmlFor="oc-staff">Staff member</Label>
        <select id="oc-staff" className={SELECT} {...register('staffId')}>
          <option value="">Choose…</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
        {errors.staffId && <p className="text-sm text-destructive">{errors.staffId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="oc-manager">Reports to</Label>
        <select id="oc-manager" className={SELECT} {...register('managerId')}>
          <option value="">No one</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
      </div>
      <Button type="submit" disabled={pending}>
        Save
      </Button>
    </form>
  );
}
