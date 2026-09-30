'use client';

import { useState, useTransition } from 'react';
import { useRouter } from 'next/navigation';
import { useForm } from 'react-hook-form';
import { zodResolver } from '@hookform/resolvers/zod';
import { toast } from 'sonner';
import { requestActivationCode, requestManualReview, verifyActivationCode } from './actions';
import { otpCodeSchema, type OtpCodeInput } from '@/lib/validation';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';

export function ActivateForm({ token, phoneHint }: { token: string; phoneHint: string }) {
  const router = useRouter();
  const [phone, setPhone] = useState<string | null>(null);
  const [serverError, setServerError] = useState<string | null>(null);
  const [queued, setQueued] = useState(false);
  const [pending, startTransition] = useTransition();

  const codeForm = useForm<OtpCodeInput>({ resolver: zodResolver(otpCodeSchema) });

  const onRequestCode = () => {
    setServerError(null);
    startTransition(async () => {
      const result = await requestActivationCode(token, { error: null, phone: null }, new FormData());
      if (result.error || !result.phone) {
        setServerError(result.error ?? 'Could not send the code.');
        return;
      }
      setPhone(result.phone);
    });
  };

  const onManualReview = () => {
    startTransition(async () => {
      const result = await requestManualReview(token);
      if (result.queued) setQueued(true);
      else setServerError('This request could not be sent. Ask the school to resend your invite.');
    });
  };

  const onVerify = codeForm.handleSubmit((values) => {
    setServerError(null);
    const fd = new FormData();
    fd.set('code', values.code);
    startTransition(async () => {
      const result = await verifyActivationCode(token, { error: null, ok: false }, fd);
      if (result.error) {
        setServerError(result.error);
        return;
      }
      // Navigate away rather than rendering a "done" state on this same
      // route — activate_guardian_account() just consumed the invite, and
      // the cookie mutations verifyOtp()/refreshSession() made trigger
      // Next.js to re-fetch this page's server data on any in-place
      // re-render, which would re-run get_guardian_invite_preview() and
      // correctly (but unhelpfully) show "invite already used" instead of
      // a success message. Same reasoning as accept-form.tsx's own
      // router.push after accept_invitation().
      toast.success('Account activated.');
      // Straight to the parent portal. A guardian has no app_user row, so
      // sending them to a staff route only bounces them through
      // (app)/layout.tsx to get here anyway.
      router.push('/portal/homework');
      router.refresh();
    });
  });

  if (queued) {
    return (
      <p role="status" className="text-sm text-muted-foreground" data-testid="activate-queued">
        The school office will verify your claim and contact you. You can close this page.
      </p>
    );
  }

  if (!phone) {
    return (
      <div className="space-y-4">
        <p className="text-sm text-muted-foreground">We&apos;ll send a verification code to {phoneHint}.</p>
        {serverError && (
          <p role="alert" className="text-sm text-destructive">
            {serverError}
          </p>
        )}
        <Button type="button" disabled={pending} onClick={onRequestCode} className="w-full" data-testid="activate-request-code">
          {pending ? 'Sending…' : 'Send code'}
        </Button>
        <Button type="button" variant="ghost" disabled={pending} onClick={onManualReview} className="w-full" data-testid="activate-manual-review">
          I can&apos;t receive the code
        </Button>
      </div>
    );
  }

  return (
    <form onSubmit={onVerify} className="space-y-4" noValidate>
      <p className="text-sm text-muted-foreground">Code sent to {phone}.</p>
      <div className="space-y-2">
        <Label htmlFor="code">6-digit code</Label>
        <Input id="code" type="text" inputMode="numeric" autoComplete="one-time-code" {...codeForm.register('code')} />
        {codeForm.formState.errors.code && <p className="text-sm text-destructive">{codeForm.formState.errors.code.message}</p>}
      </div>
      {serverError && (
        <p role="alert" className="text-sm text-destructive">
          {serverError}
        </p>
      )}
      <Button type="submit" disabled={pending} className="w-full" data-testid="activate-verify-code">
        {pending ? 'Verifying…' : 'Activate account'}
      </Button>
      <Button type="button" variant="ghost" disabled={pending} onClick={onManualReview} className="w-full" data-testid="activate-manual-review">
        I can&apos;t receive the code
      </Button>
    </form>
  );
}
