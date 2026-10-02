'use client';

import Link from 'next/link';
import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { guardianClaimSchema, type GuardianClaimInput } from '@/lib/validation';
import { startGuardianClaim } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function ClaimForm() {
  const [serverError, setServerError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const form = useForm<GuardianClaimInput>({ resolver: zodResolver(guardianClaimSchema) });

  const onSubmit = form.handleSubmit((values) => {
    setServerError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await startGuardianClaim(values);
      if (result) {
        setServerError(result.error);
        setNotice(result.notice);
      }
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="schoolCode">School code</Label>
        <Input id="schoolCode" autoCapitalize="none" autoComplete="off" {...form.register('schoolCode')} />
        {form.formState.errors.schoolCode && <p className="text-sm text-destructive">{form.formState.errors.schoolCode.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="grNumber">Your child&apos;s GR number</Label>
        <Input id="grNumber" inputMode="numeric" autoComplete="off" {...form.register('grNumber')} />
        {form.formState.errors.grNumber && <p className="text-sm text-destructive">{form.formState.errors.grNumber.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="cnicLast6">Last 6 digits of your CNIC</Label>
        <Input id="cnicLast6" inputMode="numeric" maxLength={6} autoComplete="off" {...form.register('cnicLast6')} />
        {form.formState.errors.cnicLast6 && <p className="text-sm text-destructive">{form.formState.errors.cnicLast6.message}</p>}
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive" data-testid="claim-error">
          {serverError}
        </p>
      )}
      {notice && (
        <p role="status" className="text-sm text-muted-foreground" data-testid="claim-notice">
          {notice}{' '}
          <Link href="/login" className="underline">
            Sign in
          </Link>
        </p>
      )}
      <Button type="submit" disabled={pending} className="w-full" data-testid="claim-submit">
        {pending ? 'Checking…' : 'Continue'}
      </Button>
    </form>
  );
}
