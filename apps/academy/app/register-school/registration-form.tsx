'use client';

import { useState, useTransition } from 'react';
import Link from 'next/link';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { CheckCircle2 } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { registerSchool } from './actions';
import { registrationSchema, type RegistrationInput } from './schema';

const FIELDS: { name: keyof RegistrationInput; label: string; placeholder?: string; optional?: boolean; type?: string }[] = [
  { name: 'schoolName', label: 'School name', placeholder: 'Al-Noor Grammar School' },
  { name: 'contactName', label: 'Your name', placeholder: 'Bilal Ahmed' },
  { name: 'phone', label: 'Mobile number', placeholder: '0300 1234567', type: 'tel' },
  { name: 'email', label: 'Email', optional: true, type: 'email' },
  { name: 'city', label: 'City', optional: true, placeholder: 'Lahore' },
  { name: 'students', label: 'Number of students', optional: true, placeholder: '450' },
];

export function RegistrationForm() {
  const [sent, setSent] = useState(false);
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const { register, handleSubmit, formState: { errors } } = useForm<RegistrationInput>({
    resolver: zodResolver(registrationSchema),
    defaultValues: { schoolName: '', contactName: '', phone: '', email: '', city: '', students: '', message: '' },
  });
  const onSubmit = handleSubmit((v) =>
    startTransition(async () => {
      setServerError(null);
      const r = await registerSchool(v);
      if (r.error) return setServerError(r.error);
      setSent(true);
    }),
  );

  if (sent) {
    return (
      <div className="space-y-4 text-center" data-testid="registration-sent">
        <CheckCircle2 className="mx-auto h-10 w-10 text-success" aria-hidden />
        <div className="space-y-1">
          <p className="font-medium">Thank you, we have your request.</p>
          <p className="text-sm text-muted-foreground">We will call you within one working day to set up your school and send your sign-in link.</p>
        </div>
        <Link href="/login" className="text-sm font-medium underline">
          Back to sign in
        </Link>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-3" noValidate>
      <div className="grid gap-3 sm:grid-cols-2">
        {FIELDS.map((f) => (
          <div key={f.name} className="space-y-1">
            <Label htmlFor={`rs-${f.name}`}>
              {f.label}
              {f.optional && <span className="font-normal text-muted-foreground"> (optional)</span>}
            </Label>
            <Input id={`rs-${f.name}`} type={f.type ?? 'text'} placeholder={f.placeholder} inputMode={f.name === 'students' ? 'numeric' : undefined} {...register(f.name)} />
            {errors[f.name] && <p className="text-sm text-destructive">{errors[f.name]?.message}</p>}
          </div>
        ))}
      </div>
      <div className="space-y-1">
        <Label htmlFor="rs-message">
          Anything we should know <span className="font-normal text-muted-foreground">(optional)</span>
        </Label>
        <Textarea id="rs-message" rows={3} placeholder="Campuses, current software, best time to call…" {...register('message')} />
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive">
          {serverError}
        </p>
      )}
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Sending…' : 'Request my school account'}
      </Button>
    </form>
  );
}
