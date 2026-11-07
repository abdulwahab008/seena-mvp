'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { decideRecheck, requestRecheck } from './actions';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
type Option = { id: string; label: string };

const requestSchema = z.object({
  enrolmentId: z.string().min(1, 'Choose a student'),
  subjectId: z.string().min(1, 'Choose a subject'),
  fee: z.string().regex(/^\d+(\.\d{1,2})?$/, 'Enter the fee in rupees (0 if free)'),
  reason: z.string().trim().min(1, 'Give a reason').max(500),
});

export function RecheckRequestForm({ termId, students, subjectsByStudent }: { termId: string; students: Option[]; subjectsByStudent: Record<string, Option[]> }) {
  const [pending, startTransition] = useTransition();
  const blank = { enrolmentId: '', subjectId: '', fee: '0', reason: '' };
  const { register, handleSubmit, watch, reset, formState: { errors } } = useForm<z.infer<typeof requestSchema>>({ resolver: zodResolver(requestSchema), defaultValues: blank });
  const subjects = subjectsByStudent[watch('enrolmentId')] ?? [];
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await requestRecheck({ ...v, termId, fee: Number(v.fee) });
      if (r.error) return void toast.error(r.error);
      toast.success('Re-check recorded.');
      reset(blank);
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Record a re-check request</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2" noValidate>
          <div className="space-y-1">
            <Label htmlFor="rc-student">Student</Label>
            <select id="rc-student" className={SELECT} {...register('enrolmentId')}>
              <option value="">Choose…</option>
              {students.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            {errors.enrolmentId && <p className="text-sm text-destructive">{errors.enrolmentId.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="rc-subject">Subject</Label>
            <select id="rc-subject" className={SELECT} {...register('subjectId')}>
              <option value="">Choose…</option>
              {subjects.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            {errors.subjectId && <p className="text-sm text-destructive">{errors.subjectId.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="rc-fee">Fee (PKR)</Label>
            <Input id="rc-fee" inputMode="decimal" {...register('fee')} />
            {errors.fee && <p className="text-sm text-destructive">{errors.fee.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="rc-reason">Reason</Label>
            <Input id="rc-reason" {...register('reason')} />
            {errors.reason && <p className="text-sm text-destructive">{errors.reason.message}</p>}
          </div>
          <div>
            <Button type="submit" disabled={pending}>
              Record request
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

const decideSchema = z.object({ marksAfter: z.string().regex(/^(\d+(\.\d{1,2})?)?$/, 'Enter the corrected marks'), note: z.string().trim().max(500) });

export function DecideRecheck({ id }: { id: string }) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof decideSchema>>({ resolver: zodResolver(decideSchema), defaultValues: { marksAfter: '', note: '' } });
  const decide = (changed: boolean) =>
    handleSubmit((v) =>
      startTransition(async () => {
        if (changed && v.marksAfter === '') return void toast.error('Enter the corrected marks.');
        const r = await decideRecheck({ id, changed, marksAfter: changed ? Number(v.marksAfter) : null, note: v.note });
        if (r.error) return void toast.error(r.error);
        toast.success('Outcome recorded.');
        setOpen(false);
      }),
    )();
  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
        Record outcome
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Re-check outcome"
        size="sm"
        footer={
          <>
            <Button variant="outline" onClick={() => decide(false)} disabled={pending}>
              No change
            </Button>
            <Button onClick={() => decide(true)} disabled={pending}>
              Marks changed
            </Button>
          </>
        }
      >
        <div className="space-y-3">
          <div className="space-y-1">
            <Label htmlFor={`rc-after-${id}`}>Corrected marks (if changed)</Label>
            <Input id={`rc-after-${id}`} inputMode="decimal" {...register('marksAfter')} />
            {errors.marksAfter && <p className="text-sm text-destructive">{errors.marksAfter.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor={`rc-note-${id}`}>Note</Label>
            <Input id={`rc-note-${id}`} {...register('note')} />
          </div>
        </div>
      </Modal>
    </>
  );
}
