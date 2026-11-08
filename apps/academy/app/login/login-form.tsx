'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { signIn } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const LoginSchema = z.object({
  email: z.string().trim().min(1, 'Enter your email, username or GR number'),
  password: z.string().min(1, 'Enter your password'),
});
type LoginValues = z.infer<typeof LoginSchema>;

export function LoginForm({ redirectTo, schoolCode }: { redirectTo?: string; schoolCode?: string | null }) {
  const router = useRouter();
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<LoginValues>({ resolver: zodResolver(LoginSchema) });

  const onSubmit = handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('email', values.email);
    if (schoolCode) fd.set('school', schoolCode);
    fd.set('password', values.password);
    startTransition(async () => {
      const result = await signIn({ error: null, ok: false }, fd);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      router.push(redirectTo ?? '/dashboard');
      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} className="space-y-4" noValidate>
      <div className="space-y-2">
        <Label htmlFor="email">Email, username or GR number</Label>
        <Input
          id="email"
          type="text"
          placeholder={schoolCode ? 'e.g. you@email.com or ahmed' : 'e.g. you@email.com or GR-1234'}
          autoComplete="username"
          autoCapitalize="none"
          {...register('email')}
        />
        {errors.email && <p className="text-sm text-destructive">{errors.email.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="password">Password</Label>
        <Input id="password" type="password" autoComplete="current-password" {...register('password')} />
        {errors.password && <p className="text-sm text-destructive">{errors.password.message}</p>}
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive">
          {serverError}
        </p>
      )}
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Signing in…' : 'Sign in'}
      </Button>
    </form>
  );
}
