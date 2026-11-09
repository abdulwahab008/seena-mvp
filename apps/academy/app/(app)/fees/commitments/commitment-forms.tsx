'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { todayPk } from '@/lib/dates';
import { addFeeCommitment, setFeeCommitmentStatus, writeOffBadDebt } from './actions';

const promiseSchema = z.object({
  promisedDate: z.string().min(1, 'Choose a date'),
  amountRupees: z.coerce.number().positive('Enter the amount'),
  note: z.string().trim().max(300),
});

export function PromiseButton({
  enrolmentId,
  studentName,
  outstandingRupees,
}: {
  enrolmentId: string;
  studentName: string;
  outstandingRupees: number;
}) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<z.input<typeof promiseSchema>, unknown, z.output<typeof promiseSchema>>({
    resolver: zodResolver(promiseSchema),
    defaultValues: { promisedDate: todayPk(), amountRupees: outstandingRupees, note: '' },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await addFeeCommitment({ enrolmentId, ...v });
      if (r.error) return void toast.error(r.error);
      toast.success('Promise recorded.');
      setOpen(false);
    }),
  );
  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)} data-testid="promise-btn">
        Promise
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Record a promise to pay"
        description={studentName}
        size="sm"
      >
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label htmlFor={`pd-${enrolmentId}`}>Will pay on</Label>
              <Input
                id={`pd-${enrolmentId}`}
                type="date"
                min={todayPk()}
                {...register('promisedDate')}
              />
              {errors.promisedDate && (
                <p className="text-sm text-destructive">{errors.promisedDate.message}</p>
              )}
            </div>
            <div className="space-y-1">
              <Label htmlFor={`pa-${enrolmentId}`}>Amount (Rs)</Label>
              <Input
                id={`pa-${enrolmentId}`}
                type="number"
                min={1}
                step="1"
                {...register('amountRupees')}
              />
              {errors.amountRupees && (
                <p className="text-sm text-destructive">{errors.amountRupees.message}</p>
              )}
            </div>
          </div>
          <div className="space-y-1">
            <Label htmlFor={`pn-${enrolmentId}`}>Note (optional)</Label>
            <Input id={`pn-${enrolmentId}`} maxLength={300} {...register('note')} />
          </div>
          <div className="flex justify-end gap-2 border-t pt-3">
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" disabled={pending}>
              Save promise
            </Button>
          </div>
        </form>
      </Modal>
    </>
  );
}

const writeOffSchema = z.object({
  amountRupees: z.coerce.number().positive('Enter the amount'),
  reason: z.string().trim().min(3, 'Give a reason').max(300),
});

export function WriteOffButton({
  enrolmentId,
  studentName,
  outstandingRupees,
}: {
  enrolmentId: string;
  studentName: string;
  outstandingRupees: number;
}) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<z.input<typeof writeOffSchema>, unknown, z.output<typeof writeOffSchema>>({
    resolver: zodResolver(writeOffSchema),
    defaultValues: { amountRupees: outstandingRupees, reason: '' },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await writeOffBadDebt({ enrolmentId, ...v });
      if (r.error) return void toast.error(r.error);
      toast.success('Written off as bad debt.');
      setOpen(false);
    }),
  );
  return (
    <>
      <Button size="sm" variant="ghost" onClick={() => setOpen(true)} data-testid="write-off-btn">
        Write off
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Write off as bad debt"
        description={`${studentName}. This reduces what the student owes and cannot be undone here.`}
        size="sm"
      >
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor={`wa-${enrolmentId}`}>Amount (Rs)</Label>
            <Input
              id={`wa-${enrolmentId}`}
              type="number"
              min={1}
              max={outstandingRupees}
              step="1"
              {...register('amountRupees')}
            />
            {errors.amountRupees && (
              <p className="text-sm text-destructive">{errors.amountRupees.message}</p>
            )}
          </div>
          <div className="space-y-1">
            <Label htmlFor={`wr-${enrolmentId}`}>Reason</Label>
            <Input
              id={`wr-${enrolmentId}`}
              maxLength={300}
              placeholder="e.g. Family left the city"
              {...register('reason')}
            />
            {errors.reason && <p className="text-sm text-destructive">{errors.reason.message}</p>}
          </div>
          <div className="flex justify-end gap-2 border-t pt-3">
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button type="submit" variant="destructive" disabled={pending}>
              Write off
            </Button>
          </div>
        </form>
      </Modal>
    </>
  );
}

export function CommitmentStatusButtons({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  const set = (status: 'kept' | 'broken' | 'cancelled') =>
    startTransition(async () => {
      const r = await setFeeCommitmentStatus(id, status);
      if (r.error) return void toast.error(r.error);
      toast.success(
        status === 'kept'
          ? 'Marked as paid.'
          : status === 'broken'
            ? 'Marked as broken.'
            : 'Promise cancelled.',
      );
    });
  return (
    <div className="flex gap-1">
      <Button size="sm" variant="outline" disabled={pending} onClick={() => set('kept')}>
        Kept
      </Button>
      <Button size="sm" variant="ghost" disabled={pending} onClick={() => set('broken')}>
        Broken
      </Button>
    </div>
  );
}
