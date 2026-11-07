'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { changeTemporaryPassword } from './actions';
import { PASSWORD_RULES, passwordSchema, passwordsMatch } from '@/lib/auth/password';
import { Alert } from '@/components/ui/alert';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const ChangeSchema = z
  .object({ password: passwordSchema, confirmPassword: z.string().min(1, 'Confirm your password') })
  .refine(...passwordsMatch);
type ChangeValues = z.infer<typeof ChangeSchema>;

export function ChangePasswordForm() {
  const router = useRouter();
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ChangeValues>({ resolver: zodResolver(ChangeSchema) });

  const onSubmit = handleSubmit((values) => {
    setServerError(null);
    startTransition(async () => {
      const result = await changeTemporaryPassword(values);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      router.push('/dashboard');
      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="password">New password</Label>
        <Input id="password" type="password" autoComplete="new-password" {...register('password')} />
        <ul className="space-y-0.5 text-xs text-muted-foreground">
          {PASSWORD_RULES.map((rule) => (
            <li key={rule}>• {rule}</li>
          ))}
        </ul>
        {errors.password && <p className="text-sm text-destructive">{errors.password.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="confirmPassword">Confirm new password</Label>
        <Input id="confirmPassword" type="password" autoComplete="new-password" {...register('confirmPassword')} />
        {errors.confirmPassword && <p className="text-sm text-destructive">{errors.confirmPassword.message}</p>}
      </div>
      {serverError && (
        <Alert variant="destructive">
          <p>{serverError}</p>
        </Alert>
      )}
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Saving…' : 'Save password'}
      </Button>
    </form>
  );
}
