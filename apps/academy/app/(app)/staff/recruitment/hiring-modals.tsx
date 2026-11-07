'use client';

import { useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';
import { hire, makeOffer, saveScore } from './hiring-actions';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
type Props = { applicationId: string; name: string; onClose: () => void };

function Shell({ title, formId, pending, onClose, children }: { title: string; formId: string; pending: boolean; onClose: () => void; children: React.ReactNode }) {
  return (
    <Modal
      open
      onClose={onClose}
      title={title}
      size="sm"
      footer={
        <>
          <Button variant="outline" onClick={onClose} disabled={pending}>
            Cancel
          </Button>
          <Button type="submit" form={formId} disabled={pending}>
            Save
          </Button>
        </>
      }
    >
      {children}
    </Modal>
  );
}

const AREAS = [
  { key: 'subjectKnowledge', label: 'Subject knowledge' },
  { key: 'communication', label: 'Communication' },
  { key: 'teachingDemo', label: 'Teaching demo' },
  { key: 'attitude', label: 'Attitude' },
] as const;
const scoreSchema = z.object({
  subjectKnowledge: z.string(), communication: z.string(), teachingDemo: z.string(), attitude: z.string(),
  recommendation: z.enum(['hire', 'hold', 'reject']),
  comment: z.string().max(1000),
});

export function ScoreModal({ applicationId, name, onClose }: Props) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<z.infer<typeof scoreSchema>>({
    resolver: zodResolver(scoreSchema),
    defaultValues: { subjectKnowledge: '3', communication: '3', teachingDemo: '3', attitude: '3', recommendation: 'hire', comment: '' },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveScore({ ...v, applicationId });
      if (r.error) return void toast.error(r.error);
      toast.success('Scorecard saved.');
      onClose();
    }),
  );
  return (
    <Shell title={`Interview scorecard: ${name}`} formId="score-form" pending={pending} onClose={onClose}>
      <form id="score-form" onSubmit={onSubmit} className="space-y-2" noValidate>
        {AREAS.map((a) => (
          <div key={a.key} className="grid grid-cols-[1fr_6rem] items-center gap-2">
            <Label htmlFor={`sc-${a.key}`}>{a.label}</Label>
            <select id={`sc-${a.key}`} className={SELECT} {...register(a.key)}>
              {['1', '2', '3', '4', '5'].map((n) => (
                <option key={n} value={n}>
                  {n}
                </option>
              ))}
            </select>
          </div>
        ))}
        <div className="grid grid-cols-[1fr_6rem] items-center gap-2">
          <Label htmlFor="sc-rec">Recommendation</Label>
          <select id="sc-rec" className={SELECT} {...register('recommendation')}>
            <option value="hire">Hire</option>
            <option value="hold">Hold</option>
            <option value="reject">Reject</option>
          </select>
        </div>
        <Label htmlFor="sc-comment">Comment</Label>
        <Textarea id="sc-comment" {...register('comment')} />
      </form>
    </Shell>
  );
}

const offerSchema = z.object({ salary: z.string().regex(/^\d+(\.\d{1,2})?$/, 'Enter the monthly salary'), joiningOn: z.string().min(1, 'Choose the joining date') });

export function OfferModal({ applicationId, name, onClose }: Props) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof offerSchema>>({ resolver: zodResolver(offerSchema), defaultValues: { salary: '', joiningOn: todayPk() } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await makeOffer({ ...v, applicationId });
      if (r.error) return void toast.error(r.error);
      toast.success(`Offer made to ${name}.`);
      onClose();
    }),
  );
  return (
    <Shell title={`Make an offer: ${name}`} formId="offer-form" pending={pending} onClose={onClose}>
      <form id="offer-form" onSubmit={onSubmit} className="space-y-2" noValidate>
        <Label htmlFor="of-salary">Monthly salary (PKR)</Label>
        <Input id="of-salary" inputMode="decimal" {...register('salary')} />
        {errors.salary && <p className="text-sm text-destructive">{errors.salary.message}</p>}
        <Label htmlFor="of-join">Joining date</Label>
        <Input id="of-join" type="date" {...register('joiningOn')} />
      </form>
    </Shell>
  );
}

const hireSchema = z.object({
  employeeCode: z.string().trim().min(1, 'Enter an employee code').max(30),
  gender: z.enum(['male', 'female']),
  cnic: z.string().trim().regex(/^(\d{5}-\d{7}-\d)?$/, 'Enter the CNIC as 12345-1234567-1'),
});

export function HireModal({ applicationId, name, onClose }: Props) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<z.infer<typeof hireSchema>>({ resolver: zodResolver(hireSchema), defaultValues: { employeeCode: '', gender: 'female', cnic: '' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await hire({ ...v, applicationId });
      if (r.error) return void toast.error(r.error);
      toast.success(`${name} is now on the staff.`);
      onClose();
    }),
  );
  return (
    <Shell title={`Hire ${name}`} formId="hire-form" pending={pending} onClose={onClose}>
      <form id="hire-form" onSubmit={onSubmit} className="space-y-2" noValidate>
        <p className="text-sm text-muted-foreground">Creates the staff record with the offered joining date, the opening&apos;s department and the CNIC from the application.</p>
        <Label htmlFor="hi-code">Employee code</Label>
        <Input id="hi-code" {...register('employeeCode')} />
        {errors.employeeCode && <p className="text-sm text-destructive">{errors.employeeCode.message}</p>}
        <Label htmlFor="hi-cnic">CNIC (if not on the application)</Label>
        <Input id="hi-cnic" placeholder="12345-1234567-1" {...register('cnic')} />
        {errors.cnic && <p className="text-sm text-destructive">{errors.cnic.message}</p>}
        <Label htmlFor="hi-gender">Gender</Label>
        <select id="hi-gender" className={SELECT} {...register('gender')}>
          <option value="female">Female</option>
          <option value="male">Male</option>
        </select>
      </form>
    </Shell>
  );
}
