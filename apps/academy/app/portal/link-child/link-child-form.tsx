'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { guardianClaimSchema, type GuardianClaimInput } from '@/lib/validation';
import { linkAnotherChild } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const fields = guardianClaimSchema.pick({ grNumber: true, cnicLast6: true });
type Fields = Pick<GuardianClaimInput, 'grNumber' | 'cnicLast6'>;

export function LinkChildForm() {
  const [error, setError] = useState<string | null>(null);
  const [linked, setLinked] = useState(false);
  const [pending, startTransition] = useTransition();
  const form = useForm<Fields>({ resolver: zodResolver(fields) });

  const onSubmit = form.handleSubmit((values) => {
    setError(null);
    setLinked(false);
    startTransition(async () => {
      const result = await linkAnotherChild(values);
      setError(result.error);
      setLinked(result.linked);
      if (result.linked) form.reset();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="grNumber">Child&apos;s GR number</Label>
        <Input id="grNumber" inputMode="numeric" autoComplete="off" {...form.register('grNumber')} />
        {form.formState.errors.grNumber && <p className="text-sm text-destructive">{form.formState.errors.grNumber.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="cnicLast6">Last 6 digits of your CNIC</Label>
        <Input id="cnicLast6" inputMode="numeric" maxLength={6} autoComplete="off" {...form.register('cnicLast6')} />
        {form.formState.errors.cnicLast6 && <p className="text-sm text-destructive">{form.formState.errors.cnicLast6.message}</p>}
      </div>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {linked && (
        <p role="status" className="text-sm text-emerald-700">
          Child added to your portal.
        </p>
      )}
      <Button type="submit" disabled={pending}>
        {pending ? 'Checking…' : 'Add child'}
      </Button>
    </form>
  );
}
