'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { signUp } from './actions';
import { PASSWORD_RULES, passwordSchema, passwordsMatch } from '@/lib/auth/password';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Alert } from '@/components/ui/alert';

const SignUpSchema = z.object({
  fullName: z.string().trim().min(2, 'Enter your full name').max(120, 'That name is too long'),
  email: z.string().trim().email('Enter a valid email address'),
  password: passwordSchema,
  confirmPassword: z.string().min(1, 'Confirm your password'),
}).refine(...passwordsMatch);
type SignUpValues = z.infer<typeof SignUpSchema>;

export function SignUpForm() {
  const router = useRouter();
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<SignUpValues>({ resolver: zodResolver(SignUpSchema) });

  const onSubmit = handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('fullName', values.fullName);
    fd.set('email', values.email);
    fd.set('password', values.password);
    fd.set('confirmPassword', values.confirmPassword);
    startTransition(async () => {
      const result = await signUp({ error: null, ok: false }, fd);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      // Confirmations are off (supabase/config.toml auth.email
      // enable_confirmations = false), so signUp already minted a session.
      // The account has no tenant membership yet, so /no-school — not
      // /dashboard — is the only page that can say anything useful.
      router.push('/no-school');
      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate data-testid="sign-up-form">
      <div className="space-y-2">
        <Label htmlFor="fullName">Full name</Label>
        <Input id="fullName" autoComplete="name" {...register('fullName')} />
        {errors.fullName && <p className="text-sm text-destructive">{errors.fullName.message}</p>}
      </div>

      <div className="space-y-2">
        <Label htmlFor="email">Email</Label>
        <Input id="email" type="email" autoComplete="email" {...register('email')} />
        {errors.email && <p className="text-sm text-destructive">{errors.email.message}</p>}
      </div>

      <div className="space-y-2">
        <Label htmlFor="password">Password</Label>
        <Input id="password" type="password" autoComplete="new-password" {...register('password')} />
        <ul className="space-y-0.5 text-xs text-muted-foreground" data-testid="password-rules">
          {PASSWORD_RULES.map((rule) => (
            <li key={rule}>• {rule}</li>
          ))}
        </ul>
        {errors.password && <p className="text-sm text-destructive">{errors.password.message}</p>}
      </div>

      <div className="space-y-2">
        <Label htmlFor="confirmPassword">Confirm password</Label>
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
        <Alert variant="destructive" data-testid="sign-up-error">
          <p>{serverError}</p>
        </Alert>
      )}

      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Creating account…' : 'Create account'}
      </Button>
    </form>
  );
}
