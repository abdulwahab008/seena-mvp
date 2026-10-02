'use client';

import { useState, useTransition } from 'react';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { requestPasswordReset } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Alert } from '@/components/ui/alert';

const ForgotSchema = z.object({ email: z.string().trim().email('Enter a valid email address') });
type ForgotValues = z.infer<typeof ForgotSchema>;

export function ForgotPasswordForm() {
  const [serverError, setServerError] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ForgotValues>({ resolver: zodResolver(ForgotSchema) });

  const onSubmit = handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('email', values.email);
    startTransition(async () => {
      const result = await requestPasswordReset({ error: null, sent: false }, fd);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      setSent(true);
    });
  });

  // One neutral confirmation, shown for every address that parses — a real
  // account, a stranger's, or one that has never existed.
  if (sent) {
    return (
      <Alert variant="success" title="Check your email" data-testid="reset-requested">
        <p>
          If that address has a Seena Academy account, a password reset link is on its way. It
          expires in one hour and can be used once.
        </p>
      </Alert>
    );
  }

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate data-testid="forgot-password-form">
      <div className="space-y-2">
        <Label htmlFor="email">Email</Label>
        <Input id="email" type="email" autoComplete="email" {...register('email')} />
        {errors.email && <p className="text-sm text-destructive">{errors.email.message}</p>}
      </div>

      {serverError && (
        <Alert variant="destructive" data-testid="forgot-password-error">
          <p>{serverError}</p>
        </Alert>
      )}

      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Sending…' : 'Send reset link'}
      </Button>
    </form>
  );
}
