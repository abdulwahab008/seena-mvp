'use client';

import { useTransition } from 'react';
import { useForm, Controller } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { applyLeave } from './actions';
import { applyLeaveSchema, type ApplyLeaveInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';

export type LeaveType = { id: string; code: string; name_en: string };

export function ApplyLeaveForm({
  staffId,
  leaveTypes,
  balances,
}: {
  staffId: string;
  leaveTypes: LeaveType[];
  balances: Record<string, number>;
}) {
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    control,
    reset,
    watch,
    formState: { errors },
  } = useForm<ApplyLeaveInput>({
    resolver: zodResolver(applyLeaveSchema),
    defaultValues: { leaveTypeId: leaveTypes[0]?.id ?? '', fromDate: '', toDate: '', isHalfDay: false, reason: '' },
  });
  const isHalfDay = watch('isHalfDay');

  const onSubmit = handleSubmit((values) => {
    const fd = new FormData();
    fd.set('leaveTypeId', values.leaveTypeId);
    fd.set('fromDate', values.fromDate);
    fd.set('toDate', values.isHalfDay ? values.fromDate : values.toDate);
    if (values.isHalfDay) fd.set('isHalfDay', 'on');
    if (values.reason) fd.set('reason', values.reason);

    startTransition(async () => {
      const result = await applyLeave(staffId, { error: null }, fd);
      if (result.error) toast.error(result.error);
      else {
        toast.success('Leave application submitted.');
        reset({ leaveTypeId: values.leaveTypeId, fromDate: '', toDate: '', isHalfDay: false, reason: '' });
      }
    });
  });

  return (
    <div className="space-y-3 rounded-lg border p-4">
      <div className="flex flex-wrap gap-2">
        {leaveTypes.map((t) => (
          <span
            key={t.id}
            data-testid={`leave-balance-${t.code}`}
            className="rounded-full border px-3 py-1 text-xs text-muted-foreground"
          >
            {t.name_en}: {(balances[t.id] ?? 0).toFixed(2)}d left
          </span>
        ))}
      </div>
      <form onSubmit={onSubmit} className="grid grid-cols-2 gap-3 md:grid-cols-4" noValidate>
        <div className="space-y-1">
          <Label htmlFor="leaveTypeId">Leave type</Label>
          <Controller
            control={control}
            name="leaveTypeId"
            render={({ field }) => (
              <Select value={field.value} onValueChange={field.onChange}>
                <SelectTrigger data-testid="leave-type-trigger">
                  <SelectValue placeholder="Select a leave type" />
                </SelectTrigger>
                <SelectContent>
                  {leaveTypes.map((t) => (
                    <SelectItem key={t.id} value={t.id}>
                      {t.name_en}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            )}
          />
          {errors.leaveTypeId && <p className="text-xs text-destructive">{errors.leaveTypeId.message}</p>}
        </div>
        <div className="space-y-1">
          <Label htmlFor="fromDate">From</Label>
          <Input id="fromDate" type="date" {...register('fromDate')} />
          {errors.fromDate && <p className="text-xs text-destructive">{errors.fromDate.message}</p>}
        </div>
        {!isHalfDay && (
          <div className="space-y-1">
            <Label htmlFor="toDate">To</Label>
            <Input id="toDate" type="date" {...register('toDate')} />
            {errors.toDate && <p className="text-xs text-destructive">{errors.toDate.message}</p>}
          </div>
        )}
        <label className="flex items-center gap-2 self-end pb-2 text-sm">
          <input type="checkbox" {...register('isHalfDay')} />
          Half day
        </label>
        <div className="col-span-2 space-y-1 md:col-span-4">
          <Label htmlFor="reason">Reason (optional)</Label>
          <Input id="reason" {...register('reason')} />
        </div>
        <Button type="submit" disabled={pending} className="col-span-2 w-fit md:col-span-1">
          {pending ? 'Submitting…' : 'Apply for leave'}
        </Button>
      </form>
    </div>
  );
}
