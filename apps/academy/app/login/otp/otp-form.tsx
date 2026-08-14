'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { requestOtp, verifyOtpCode } from './actions';
import { otpPhoneSchema, otpCodeSchema, type OtpPhoneInput, type OtpCodeInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function OtpForm() {
  const router = useRouter();
  const [phone, setPhone] = useState<string | null>(null);
  const [serverError, setServerError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const phoneForm = useForm<OtpPhoneInput>({ resolver: zodResolver(otpPhoneSchema) });
  const codeForm = useForm<OtpCodeInput>({ resolver: zodResolver(otpCodeSchema) });

  const onRequestOtp = phoneForm.handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('phone', values.phone);
    startTransition(async () => {
      const result = await requestOtp({ error: null, phone: null }, fd);
      if (result.error || !result.phone) {
        setServerError(result.error ?? 'Could not send the code.');
        return;
      }
      setPhone(result.phone);
    });
  });

  const onVerify = codeForm.handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('phone', phone ?? '');
    fd.set('code', values.code);
    startTransition(async () => {
      const result = await verifyOtpCode({ error: null, ok: false }, fd);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      router.push('/dashboard');
      router.refresh();
    });
  });

  if (!phone) {
    return (
      <form onSubmit={onRequestOtp} className="space-y-4" noValidate>
        <div className="space-y-2">
          <Label htmlFor="phone">Mobile number</Label>
          <Input id="phone" type="tel" placeholder="03001234567" autoComplete="tel" {...phoneForm.register('phone')} />
          {phoneForm.formState.errors.phone && (
            <p className="text-sm text-destructive">{phoneForm.formState.errors.phone.message}</p>
          )}
        </div>
        {serverError && (
          <p role="alert" className="text-sm text-destructive">
            {serverError}
          </p>
        )}
        <Button type="submit" disabled={pending} className="w-full">
          {pending ? 'Sending…' : 'Send code'}
        </Button>
      </form>
    );
  }

  return (
    <form onSubmit={onVerify} className="space-y-4" noValidate>
      <p className="text-sm text-muted-foreground">Code sent to {phone}.</p>
      <div className="space-y-2">
        <Label htmlFor="code">6-digit code</Label>
        <Input id="code" type="text" inputMode="numeric" autoComplete="one-time-code" {...codeForm.register('code')} />
        {codeForm.formState.errors.code && (
          <p className="text-sm text-destructive">{codeForm.formState.errors.code.message}</p>
        )}
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive">
          {serverError}
        </p>
      )}
      <Button type="submit" disabled={pending} className="w-full">
        {pending ? 'Verifying…' : 'Verify and sign in'}
      </Button>
      <button
        type="button"
        onClick={() => {
          setPhone(null);
          setServerError(null);
          codeForm.reset();
        }}
        className="w-full text-sm text-muted-foreground underline"
      >
        Use a different number
      </button>
    </form>
  );
}
