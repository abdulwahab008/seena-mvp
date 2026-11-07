'use client';

import { useTransition } from 'react';
import { useForm, type FieldValues, type Path, type UseFormRegister } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { toast } from 'sonner';
import { formatPkr } from '@/lib/challan/html';
import { todayPk } from '@/lib/dates';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { addDonation, addDonor, addSponsorship, applySponsorships, endSponsorship } from './actions';
import { donationSchema, donorSchema, sponsorshipSchema, type DonationInput, type DonorInput, type SponsorshipInput } from './schema';

const SELECT = 'flex h-10 w-full rounded-md border border-input bg-background px-3 py-2 text-sm';
type Option = { id: string; label: string };

function Field<T extends FieldValues>({ id, label, name, register, error, type, options }: {
  id: string; label: string; name: Path<T>; register: UseFormRegister<T>; error?: string; type?: string; options?: Option[];
}) {
  return (
    <div className="space-y-1">
      <Label htmlFor={id}>{label}</Label>
      {options ? (
        <select id={id} className={SELECT} {...register(name)}>
          {options.map((o) => (
            <option key={o.id} value={o.id}>
              {o.label}
            </option>
          ))}
        </select>
      ) : (
        <Input id={id} type={type} {...register(name)} />
      )}
      {error && <p className="text-sm text-destructive">{error}</p>}
    </div>
  );
}

function useAction<T extends FieldValues>(schema: z.ZodType<T>, blank: T, run: (v: T) => Promise<{ error: string | null }>, ok: string) {
  const [pending, startTransition] = useTransition();
  const form = useForm<T>({ resolver: zodResolver(schema), defaultValues: blank as never });
  const onSubmit = form.handleSubmit((v) =>
    startTransition(async () => {
      const r = await run(v);
      if (r.error) return void toast.error(r.error);
      toast.success(ok);
      form.reset(blank as never);
    }),
  );
  return { form, onSubmit, pending };
}

export function DonorForm() {
  const blank: DonorInput = { name: '', phone: '' };
  const { form, onSubmit, pending } = useAction(donorSchema, blank, addDonor, 'Donor added.');
  const e = form.formState.errors;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Add a donor</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="space-y-3" noValidate>
          <Field id="dn-name" label="Name" name="name" register={form.register} error={e.name?.message} />
          <Field id="dn-phone" label="Phone" name="phone" register={form.register} />
          <Button type="submit" disabled={pending}>
            Add donor
          </Button>
        </form>
      </CardContent>
    </Card>
  );
}

const MODES: Option[] = ['cash', 'bank', 'cheque', 'online'].map((m) => ({ id: m, label: m[0]!.toUpperCase() + m.slice(1) }));
const PURPOSES: Option[] = [
  { id: 'general', label: 'General' },
  { id: 'zakat', label: 'Zakat' },
  { id: 'sadaqah', label: 'Sadaqah' },
  { id: 'building', label: 'Building fund' },
  { id: 'sponsorship', label: 'Sponsorship' },
];

export function DonationForm({ donors }: { donors: Option[] }) {
  const blank: DonationInput = { donorId: '', amount: '', receivedOn: todayPk(), mode: 'cash', purpose: 'general', reference: '' };
  const { form, onSubmit, pending } = useAction(donationSchema, blank, addDonation, 'Donation recorded.');
  const e = form.formState.errors;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Record a donation</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-2" noValidate>
          <Field id="do-donor" label="Donor" name="donorId" register={form.register} error={e.donorId?.message} options={[{ id: '', label: 'Choose…' }, ...donors]} />
          <Field id="do-amount" label="Amount (PKR)" name="amount" register={form.register} error={e.amount?.message} />
          <Field id="do-date" label="Received on" name="receivedOn" type="date" register={form.register} error={e.receivedOn?.message} />
          <Field id="do-mode" label="Mode" name="mode" register={form.register} options={MODES} />
          <Field id="do-purpose" label="Purpose" name="purpose" register={form.register} options={PURPOSES} />
          <Field id="do-ref" label="Reference" name="reference" register={form.register} />
          <div>
            <Button type="submit" disabled={pending}>
              Record donation
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

export function SponsorshipForm({ donors }: { donors: Option[] }) {
  const blank: SponsorshipInput = { donorId: '', grNumber: '', monthly: '' };
  const { form, onSubmit, pending } = useAction(sponsorshipSchema, blank, addSponsorship, 'Sponsorship saved.');
  const e = form.formState.errors;
  return (
    <Card>
      <CardHeader>
        <CardTitle className="text-base">Sponsor a student</CardTitle>
      </CardHeader>
      <CardContent>
        <form onSubmit={onSubmit} className="grid gap-3 sm:grid-cols-3" noValidate>
          <Field id="sp-donor" label="Sponsor" name="donorId" register={form.register} error={e.donorId?.message} options={[{ id: '', label: 'Choose…' }, ...donors]} />
          <Field id="sp-gr" label="Student GR number" name="grNumber" register={form.register} error={e.grNumber?.message} />
          <Field id="sp-monthly" label="Monthly amount (PKR)" name="monthly" register={form.register} error={e.monthly?.message} />
          <div>
            <Button type="submit" disabled={pending}>
              Save sponsorship
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  );
}

const monthSchema = z.object({ month: z.string().regex(/^\d{4}-\d{2}$/, 'Choose a month') });

export function ApplySponsorships() {
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit } = useForm<z.infer<typeof monthSchema>>({ resolver: zodResolver(monthSchema), defaultValues: { month: todayPk().slice(0, 7) } });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      const r = await applySponsorships(v.month);
      if (r.error) return void toast.error(r.error);
      toast.success(r.paid ? `Paid ${r.paid} ${r.paid === 1 ? "student's" : "students'"} fees, ${formatPkr(r.totalPaisa ?? 0)} in all.` : 'Nothing to pay for that month.');
    }),
  );
  return (
    <form onSubmit={onSubmit} className="flex flex-wrap items-end gap-2" noValidate>
      <div className="space-y-1">
        <Label htmlFor="sp-month">Month</Label>
        <Input id="sp-month" type="month" {...register('month')} />
      </div>
      <Button type="submit" disabled={pending}>
        Pay sponsored fees
      </Button>
    </form>
  );
}

export function EndSponsorship({ id }: { id: string }) {
  const [pending, startTransition] = useTransition();
  return (
    <Button
      size="sm"
      variant="ghost"
      disabled={pending}
      onClick={() =>
        startTransition(async () => {
          const r = await endSponsorship(id);
          if (r.error) return void toast.error(r.error);
          toast.success('Sponsorship ended.');
        })
      }
    >
      End
    </Button>
  );
}
