'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { addApplicant, moveApplicant, saveOpening } from './actions';
import { HireModal, OfferModal, ScoreModal } from './hiring-modals';
import { formatDateTimePk } from '@/lib/dates';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Modal } from '@/components/ui/modal';
import { Textarea } from '@/components/ui/textarea';

const openingSchema = z.object({
  title: z.string().trim().min(1, 'Enter a title').max(150),
  positions: z.string().regex(/^\d+$/, 'Enter a number'),
  salaryRange: z.string().max(100),
  closesOn: z.string(),
  description: z.string().max(4000),
});

export function OpeningForm({ campusId }: { campusId: string }) {
  const router = useRouter();
  const [pending, startTransition] = useTransition();
  const blank = { title: '', positions: '1', salaryRange: '', closesOn: '', description: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof openingSchema>>({ resolver: zodResolver(openingSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await saveOpening({ ...v, campusId });
      if (r.error) return void toast.error(r.error);
      toast.success('Opening posted.');
      reset(blank);
      router.push(`/staff/recruitment?job=${r.id}`);
    }),
  );
  return (
    <form onSubmit={onSubmit} className="space-y-2 rounded-md border p-3" noValidate>
      <p className="text-sm font-medium">New opening</p>
      <Label htmlFor="job-title">Job title</Label>
      <Input id="job-title" {...register('title')} />
      {errors.title && <p className="text-sm text-destructive">{errors.title.message}</p>}
      <div className="grid grid-cols-2 gap-2">
        <div className="space-y-1">
          <Label htmlFor="job-positions">Posts</Label>
          <Input id="job-positions" type="number" min={1} {...register('positions')} />
        </div>
        <div className="space-y-1">
          <Label htmlFor="job-closes">Closes on</Label>
          <Input id="job-closes" type="date" {...register('closesOn')} />
        </div>
      </div>
      <Label htmlFor="job-salary">Salary range</Label>
      <Input id="job-salary" {...register('salaryRange')} />
      <Label htmlFor="job-description">Requirements</Label>
      <Textarea id="job-description" {...register('description')} />
      <Button type="submit" size="sm" disabled={pending} className="w-full">
        Post opening
      </Button>
    </form>
  );
}

const applicantSchema = z.object({
  candidateName: z.string().trim().min(1, 'Enter a name').max(200),
  phone: z.string().max(30),
  email: z.string().max(200),
  cnic: z.string().max(15),
  qualification: z.string().max(300),
  experienceYrs: z.string(),
  source: z.string().max(100),
});

export function ApplicantForm({ jobOpeningId }: { jobOpeningId: string }) {
  const [pending, startTransition] = useTransition();
  const blank = { candidateName: '', phone: '', email: '', cnic: '', qualification: '', experienceYrs: '', source: '' };
  const { register, handleSubmit, reset, formState: { errors } } = useForm<z.infer<typeof applicantSchema>>({ resolver: zodResolver(applicantSchema), defaultValues: blank });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await addApplicant({ ...v, jobOpeningId });
      if (r.error) return void toast.error(r.error);
      toast.success('Applicant added.');
      reset(blank);
    }),
  );
  const field = (id: string, label: string, name: keyof z.infer<typeof applicantSchema>, type = 'text') => (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      <Input id={id} type={type} {...register(name)} />
    </div>
  );
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Add an applicant</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
          <div className="space-y-1">
            <Label htmlFor="app-name">Candidate name</Label>
            <Input id="app-name" {...register('candidateName')} />
            {errors.candidateName && <p className="text-sm text-destructive">{errors.candidateName.message}</p>}
          </div>
          {field('app-phone', 'Mobile', 'phone', 'tel')}
          {field('app-email', 'Email', 'email', 'email')}
          {field('app-cnic', 'CNIC', 'cnic')}
          {field('app-qualification', 'Qualification', 'qualification')}
          {field('app-experience', 'Experience (years)', 'experienceYrs', 'number')}
          {field('app-source', 'Source', 'source')}
          <Button type="submit" disabled={pending} className="self-end">
            Add applicant
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

type Applicant = { id: string; name: string; contact: string; profile: string; stage: string; interviewAt: string | null; lastNote: string | null; score: string | null; offer: string | null };
type Stage = 'shortlisted' | 'interview' | 'offered' | 'hired' | 'rejected' | 'withdrawn';

const NEXT: Record<string, Stage[]> = {
  applied: ['shortlisted', 'rejected'],
  shortlisted: ['interview', 'rejected'],
  interview: ['offered', 'rejected'],
  offered: ['hired', 'withdrawn'],
};
const LABEL: Record<string, string> = {
  applied: 'Applied', shortlisted: 'Shortlisted', interview: 'Interview', offered: 'Offered', hired: 'Hired', rejected: 'Rejected', withdrawn: 'Withdrawn',
};
const ACTION: Record<Stage, string> = { shortlisted: 'Shortlist', interview: 'Schedule interview', offered: 'Make offer', hired: 'Mark hired', rejected: 'Reject', withdrawn: 'Withdrew' };
const ORDER = ['applied', 'shortlisted', 'interview', 'offered', 'hired', 'rejected', 'withdrawn'];

const moveSchema = z.object({ note: z.string().max(1000), interviewAt: z.string() });

function MoveModal({ applicant, stage, onClose }: { applicant: Applicant; stage: Stage; onClose: () => void }) {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<z.infer<typeof moveSchema>>({ resolver: zodResolver(moveSchema), defaultValues: { note: '', interviewAt: '' } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await moveApplicant({
        applicationId: applicant.id,
        stage,
        note: v.note || undefined,
        interviewAt: v.interviewAt ? new Date(v.interviewAt).toISOString() : undefined,
      });
      if (r.error) return void toast.error(r.error);
      toast.success(`${applicant.name}: ${LABEL[stage]?.toLowerCase()}.`);
      onClose();
    }),
  );
  return (
    <Modal
      open
      onClose={onClose}
      title={`${ACTION[stage]}: ${applicant.name}`}
      size="sm"
      footer={
        <>
          <Button variant="outline" onClick={onClose} disabled={pending}>Cancel</Button>
          <Button type="submit" form="move-form" disabled={pending}>Save</Button>
        </>
      }
    >
      <form id="move-form" onSubmit={onSubmit} className="space-y-2" noValidate>
        {stage === 'interview' && (
          <>
            <Label htmlFor="move-when">Interview time</Label>
            <Input id="move-when" type="datetime-local" {...register('interviewAt')} />
          </>
        )}
        <Label htmlFor="move-note">Note (optional)</Label>
        <Textarea id="move-note" {...register('note')} />
      </form>
    </Modal>
  );
}

export function ApplicantBoard({ applicants }: { applicants: Applicant[] }) {
  const [moving, setMoving] = useState<{ applicant: Applicant; stage: Stage } | null>(null);
  const [scoring, setScoring] = useState<Applicant | null>(null);
  if (applicants.length === 0) return <p className="text-sm text-muted-foreground">No applicants yet.</p>;
  const sorted = [...applicants].sort((a, b) => ORDER.indexOf(a.stage) - ORDER.indexOf(b.stage));
  return (
    <div className="space-y-2">
      {sorted.map((a) => (
        <div key={a.id} className="flex flex-wrap items-start justify-between gap-3 rounded-md border p-3 text-sm" data-testid="applicant-row">
          <div className="min-w-0 space-y-0.5">
            <p className="font-medium">
              {a.name}{' '}
              <Badge variant={a.stage === 'hired' ? 'success' : a.stage === 'rejected' || a.stage === 'withdrawn' ? 'outline' : 'primary'} data-testid="applicant-stage">
                {LABEL[a.stage]}
              </Badge>
            </p>
            {a.contact && <p className="text-muted-foreground">{a.contact}</p>}
            {a.profile && <p className="text-muted-foreground">{a.profile}</p>}
            {a.stage === 'interview' && a.interviewAt && <p>Interview: {formatDateTimePk(a.interviewAt)}</p>}
            {a.score && <p data-testid="applicant-score">Interview score: {a.score}</p>}
            {a.offer && <p data-testid="applicant-offer">{a.offer}</p>}
            {a.lastNote && <p className="italic text-muted-foreground">“{a.lastNote}”</p>}
          </div>
          <div className="flex flex-wrap gap-1">
            {a.stage === 'interview' && (
              <Button size="sm" variant="outline" onClick={() => setScoring(a)}>
                Score interview
              </Button>
            )}
            {(NEXT[a.stage] ?? []).map((s) => (
              <Button key={s} size="sm" variant={s === 'rejected' || s === 'withdrawn' ? 'ghost' : 'outline'} onClick={() => setMoving({ applicant: a, stage: s })}>
                {ACTION[s]}
              </Button>
            ))}
          </div>
        </div>
      ))}
      {moving?.stage === 'offered' && <OfferModal applicationId={moving.applicant.id} name={moving.applicant.name} onClose={() => setMoving(null)} />}
      {moving?.stage === 'hired' && <HireModal applicationId={moving.applicant.id} name={moving.applicant.name} onClose={() => setMoving(null)} />}
      {moving && moving.stage !== 'offered' && moving.stage !== 'hired' && <MoveModal applicant={moving.applicant} stage={moving.stage} onClose={() => setMoving(null)} />}
      {scoring && <ScoreModal applicationId={scoring.id} name={scoring.name} onClose={() => setScoring(null)} />}
    </div>
  );
}
