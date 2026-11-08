'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { z } from 'zod';
import { acceptInvite } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

const PasswordSchema = z.object({
  fullName: z.string().trim().min(2, 'Enter your full name').max(120),
  username: z.union([z.literal(''), z.string().trim().regex(/^[a-zA-Z0-9][a-zA-Z0-9._-]{2,31}$/, '3 to 32 letters, numbers, dots, dashes or underscores')]),
  password: z.string().min(10, 'Must be at least 10 characters'),
});
type PasswordValues = z.infer<typeof PasswordSchema>;

export function AcceptForm({ token, email, schoolCode }: { token: string; email: string; schoolCode: string | null }) {
  const router = useRouter();
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<PasswordValues>({ resolver: zodResolver(PasswordSchema), defaultValues: { fullName: '', username: '', password: '' } });

  const onSubmit = handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('token', token);
    fd.set('password', values.password);
    fd.set('fullName', values.fullName);
    fd.set('username', values.username);
    startTransition(async () => {
      const result = await acceptInvite(email, { error: null, ok: false }, fd);
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
        <Label htmlFor="email">Email</Label>
        <Input id="email" type="email" value={email} disabled />
      </div>
      <div className="space-y-2">
        <Label htmlFor="fullName">Your full name</Label>
        <Input id="fullName" autoComplete="name" {...register('fullName')} />
        {errors.fullName && <p className="text-sm text-destructive">{errors.fullName.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="username">
          Username <span className="font-normal text-muted-foreground">(optional)</span>
        </Label>
        <Input id="username" autoComplete="username" autoCapitalize="none" placeholder="e.g. ahmed.k" {...register('username')} />
        <p className="text-xs text-muted-foreground">
          {schoolCode ? `Sign in later with yourusername@${schoolCode}, or your email.` : 'Sign in later with your username or your email.'}
        </p>
        {errors.username && <p className="text-sm text-destructive">{errors.username.message}</p>}
      </div>
      <div className="space-y-2">
        <Label htmlFor="password">Choose a password</Label>
        <Input id="password" type="password" autoComplete="new-password" {...register('password')} />
        {errors.password && <p className="text-sm text-destructive">{errors.password.message}</p>}
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive">
          {serverError}
        </p>
      )}
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Creating account…' : 'Accept invitation'}
      </Button>
    </form>
  );
}
