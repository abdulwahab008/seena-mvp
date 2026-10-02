'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { resetPassword } from './actions';
import { PASSWORD_RULES, passwordSchema, passwordsMatch } from '@/lib/auth/password';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Alert } from '@/components/ui/alert';

const ResetSchema = z.object({
  password: passwordSchema,
  confirmPassword: z.string().min(1, 'Confirm your password'),
}).refine(...passwordsMatch);
type ResetValues = z.infer<typeof ResetSchema>;

export function ResetPasswordForm({ tokenHash }: { tokenHash: string }) {
  const router = useRouter();
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<ResetValues>({ resolver: zodResolver(ResetSchema) });

  const onSubmit = handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('tokenHash', tokenHash);
    fd.set('password', values.password);
    fd.set('confirmPassword', values.confirmPassword);
    startTransition(async () => {
      const result = await resetPassword({ error: null, ok: false }, fd);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      router.push('/login?reset=1');
      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate data-testid="reset-password-form">
      <div className="space-y-2">
        <Label htmlFor="password">New password</Label>
        <Input id="password" type="password" autoComplete="new-password" {...register('password')} />
        <ul className="space-y-0.5 text-xs text-muted-foreground" data-testid="password-rules">
          {PASSWORD_RULES.map((rule) => (
            <li key={rule}>• {rule}</li>
          ))}
        </ul>
        {errors.password && <p className="text-sm text-destructive">{errors.password.message}</p>}
      </div>

      <div className="space-y-2">
        <Label htmlFor="confirmPassword">Confirm new password</Label>
        <Input
          id="confirmPassword"
          type="password"
          autoComplete="new-password"
          {...register('confirmPassword')}
        />
        {errors.confirmPassword && (
          <p className="text-sm text-destructive">{errors.confirmPassword.message}</p>
        )}
      </div>

      {serverError && (
        <Alert variant="destructive" data-testid="reset-password-error">
          <p>{serverError}</p>
        </Alert>
      )}

      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Updating password…' : 'Update password'}
      </Button>
    </form>
  );
}
