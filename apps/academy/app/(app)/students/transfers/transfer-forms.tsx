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
import { decideTransfer, requestTransfer } from './actions';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
const schema = z.object({
  grNumber: z.string().trim().min(1, 'Enter the GR number'),
  sectionId: z.string().min(1, 'Choose a section'),
  reason: z.string().trim().min(1, 'Give a reason').max(500),
});

export function TransferRequestForm({ sections }: { sections: { id: string; label: string }[] }) {
  const [pending, startTransition] = useTransition();
  const blank = { grNumber: '', sectionId: '', reason: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof schema>>({ resolver: zodResolver(schema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await requestTransfer(v);
      if (r.error) return void toast.error(r.error);
      toast.success('Transfer requested. The receiving campus will decide.');
      reset(blank);
    }),
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Request a transfer</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="tr-gr">GR number</Label>
            <Input id="tr-gr" {...register('grNumber')} />
            {errors.grNumber && <p className="text-sm text-destructive">{errors.grNumber.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="tr-section">New campus and section</Label>
            <select id="tr-section" className={SELECT} {...register('sectionId')}>
              <option value="">Choose…</option>
              {sections.map((s) => (
                <option key={s.id} value={s.id}>
                  {s.label}
                </option>
              ))}
            </select>
            {errors.sectionId && <p className="text-sm text-destructive">{errors.sectionId.message}</p>}
          </div>
          <div className="space-y-1">
            <Label htmlFor="tr-reason">Reason</Label>
            <Input id="tr-reason" {...register('reason')} />
            {errors.reason && <p className="text-sm text-destructive">{errors.reason.message}</p>}
          </div>
          <div>
            <Button type="submit" disabled={pending}>
              Request transfer
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

const noteSchema = z.object({ note: z.string().trim().max(500) });

export function DecideTransfer({ id }: { id: string }) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<z.infer<typeof noteSchema>>({ resolver: zodResolver(noteSchema), defaultValues: { note: '' } });
  const decide = (approve: boolean) =>
    handleSubmit((v) =>
      startTransition(async () => {
        const r = await decideTransfer(id, approve, v.note);
        if (r.error) return void toast.error(r.error);
        toast.success(approve ? 'Student transferred.' : 'Transfer declined.');
        setOpen(false);
      }),
    )();
  return (
    <>
      <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
        Decide
      </Button>
      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Accept this student?"
        description="Approving moves the student and this session's enrolment to your campus today."
        size="sm"
        footer={
          <>
            <Button variant="outline" onClick={() => decide(false)} disabled={pending}>
              Decline
            </Button>
            <Button onClick={() => decide(true)} disabled={pending}>
              Approve transfer
            </Button>
          </>
        }
      >
        <div className="space-y-1">
          <Label htmlFor={`tr-note-${id}`}>Note (optional)</Label>
          <Input id={`tr-note-${id}`} maxLength={500} {...register('note')} />
        </div>
      </Modal>
    </>
  );
}
