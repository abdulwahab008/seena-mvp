'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { endEnrolment, enrolInBatch, postCoachingCharges, saveBatch } from './actions';
import { batchSchema, coachingEnrolSchema, postMonthSchema, type BatchInput, type CoachingEnrolInput, type PostMonthInput } from './schema';

const select = 'h-10 w-full rounded-md border bg-background px-3 text-sm';

export type BatchRow = { id: string; name: string; subject: string | null; teacher_staff_id: string | null; monthly_fee_paisa: number; schedule: string | null; is_active: boolean };
type Option = { id: string; label: string };

export function BatchForm({ campusId, staff, batch, onDone }: { campusId: string; staff: Option[]; batch?: BatchRow; onDone?: () => void }) {
  const [pending, startTransition] = useTransition();
  const blank: BatchInput = {
    id: batch?.id, campusId, name: batch?.name ?? '', subject: batch?.subject ?? '', teacherId: batch?.teacher_staff_id ?? '',
    feePkr: batch ? String(batch.monthly_fee_paisa / 100) : '', schedule: batch?.schedule ?? '', isActive: batch?.is_active ?? true,
  };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<BatchInput>({ resolver: zodResolver(batchSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveBatch(v);
      if (r.error) return void toast.error(r.error);
      toast.success(batch ? 'Batch saved.' : 'Batch added.');
      reset(blank);
      onDone?.();
    }),
  );
  const id = (f: string) => `batch-${batch?.id ?? 'new'}-${f}`;
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2" noValidate data-testid={batch ? 'batch-edit-form' : 'batch-form'}>
      <div className="space-y-1">
        <Label htmlFor={id('name')}>Batch name</Label>
        <Input id={id('name')} placeholder="Evening Maths IX" {...register('name')} />
        {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor={id('subject')}>Subject</Label>
        <Input id={id('subject')} {...register('subject')} />
      </div>
      <div className="space-y-1">
        <Label htmlFor={id('teacher')}>Teacher</Label>
        <select id={id('teacher')} className={select} {...register('teacherId')}>
          <option value="">Not assigned</option>
          {staff.map((s) => (
            <option key={s.id} value={s.id}>
              {s.label}
            </option>
          ))}
        </select>
      </div>
      <div className="space-y-1">
        <Label htmlFor={id('fee')}>Monthly fee (PKR)</Label>
        <Input id={id('fee')} inputMode="decimal" {...register('feePkr')} />
        {errors.feePkr && <p className="text-sm text-destructive">{errors.feePkr.message}</p>}
      </div>
      <div className="space-y-1 sm:col-span-2">
        <Label htmlFor={id('schedule')}>Schedule</Label>
        <Input id={id('schedule')} placeholder="Mon to Thu, 5 to 6 pm" {...register('schedule')} />
      </div>
      {batch && (
        <label className="flex items-center gap-2 text-sm" htmlFor={id('active')}>
          <input id={id('active')} type="checkbox" {...register('isActive')} />
          Active
        </label>
      )}
      <div className="sm:col-span-2">
        <Button type="submit" disabled={pending}>
          {batch ? 'Save' : 'Add batch'}
        </Button>
      </div>
    </form>
  );
}

export function EditBatchButton({ campusId, staff, batch }: { campusId: string; staff: Option[]; batch: BatchRow }) {
  const [open, setOpen] = useState(false);
  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
        Edit
      </Button>
      {open && (
        <Modal open={open} onClose={() => setOpen(false)} title={`Edit ${batch.name}`}>
          <BatchForm campusId={campusId} staff={staff} batch={batch} onDone={() => setOpen(false)} />
        </Modal>
      )}
    </>
  );
}

export function CoachingEnrolForm({ batches }: { batches: Option[] }) {
  const [pending, startTransition] = useTransition();
  const blank: CoachingEnrolInput = { batchId: '', grNumber: '', startsOn: todayPk() };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<CoachingEnrolInput>({ resolver: zodResolver(coachingEnrolSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await enrolInBatch(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Student enrolled.');
      reset(blank);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-4" noValidate data-testid="coaching-enrol-form">
      <div className="space-y-1">
        <Label htmlFor="ce-gr">GR number</Label>
        <Input id="ce-gr" {...register('grNumber')} />
        {errors.grNumber && <p className="text-sm text-destructive">{errors.grNumber.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ce-batch">Batch</Label>
        <select id="ce-batch" className={select} {...register('batchId')}>
          <option value="">Choose</option>
          {batches.map((b) => (
            <option key={b.id} value={b.id}>
              {b.label}
            </option>
          ))}
        </select>
        {errors.batchId && <p className="text-sm text-destructive">{errors.batchId.message}</p>}
      </div>
      <div className="space-y-1">
        <Label htmlFor="ce-start">From</Label>
        <Input id="ce-start" type="date" {...register('startsOn')} />
        {errors.startsOn && <p className="text-sm text-destructive">{errors.startsOn.message}</p>}
      </div>
      <div className="flex items-end">
        <Button type="submit" disabled={pending}>
          Enrol
        </Button>
      </div>
    </form>
  );
}

export function EndEnrolmentButton({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await endEnrolment(id);
          if (r.error) toast.error(r.error);
          else toast.success('Enrolment ended today.');
        })
      }
    >
      End
    </Button>
  );
}

export function PostChargesForm() {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<PostMonthInput>({ resolver: zodResolver(postMonthSchema), defaultValues: { month: todayPk().slice(0, 7) } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await postCoachingCharges(v);
      if (r.error) return void toast.error(r.error);
      toast.success(r.message ?? 'Posted.');
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate data-testid="coaching-post-form">
      <div className="space-y-1">
        <Label htmlFor="cp-month">Month</Label>
        <Input id="cp-month" type="month" {...register('month')} />
        {errors.month && <p className="text-sm text-destructive">{errors.month.message}</p>}
      </div>
      <Button type="submit" variant="outline" disabled={pending}>
        Post coaching fees
      </Button>
    </form>
  );
}
